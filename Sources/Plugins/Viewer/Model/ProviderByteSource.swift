import AFMKernel
import Foundation

/// A file on any file system, read through its provider with `seek` and `read`, so the viewer
/// works wherever a panel can show files (archives, servers).
///
/// Several threads read at once, each through a reader of its own; idle readers are kept for the
/// next request.
///
/// `idle` and `closes` are guarded by `lock`; everything else is immutable.
internal final class ProviderByteSource: ByteSource, @unchecked Sendable {
    /// The most that is read to find the size of a file the file system cannot give.
    internal static let measuringLimit: Int64 = 1 << 40

    private static let measuredKeepLimit: Int64 = 16 << 20

    /// The file that is read.
    internal let url: URL
    /// The size of the file when it was opened; reads never go past it.
    internal let length: Int64
    private let provider: any FileSystemProvider
    private let lock = NSLock()
    private var idle: [any FileReader] = []
    /// How often the source was closed.
    private var closes = 0
    private let idleLimit = ProcessInfo.processInfo.activeProcessorCount

    /// A source of the `length` first bytes of `url`, read through `provider`; nothing is opened
    /// before the first read.
    internal init(url: URL, provider: any FileSystemProvider, length: Int64) {
        self.url = url
        self.provider = provider
        self.length = length
    }

    /// Opens `url` for viewing.
    ///
    /// The size comes from the directory entry; a file system that cannot tell it (or tells zero)
    /// is measured by reading the file once. A file on the local disk that the entry only knows as
    /// a link is measured by asking for the size of what it points to; pipes, devices and sockets
    /// are refused. Blocks; ends early (throwing) once `cancellation` is set.
    internal static func open(
        _ url: URL,
        fileSystems: FileSystemRegistry,
        cancellation: CancellationFlag
    )
        throws -> any ByteSource
    {
        let fileSystem = try fileSystems.provider(for: url)
        let entry = fileSystem.item(at: url, cancellation: cancellation)
        if let entry, entry.isSpecial { throw ViewerError.notAFile(url.lastPathComponent) }
        // A link to a file whose file system already knows the target's size: no need to ask for it again.
        if let entry, entry.isSymlink, !entry.isDirectory, let size = entry.linkTargetSize, size > 0 {
            return ProviderByteSource(url: url, provider: fileSystem, length: size)
        }
        if let entry, entry.size > 0, !entry.isDirectory {
            return ProviderByteSource(url: url, provider: fileSystem, length: entry.size)
        }
        try cancellation.throwIfCancelled()
        if url.isFileURL, entry?.isDirectory != true, let local = try localFile(url, provider: fileSystem) {
            return local
        }
        return try measure(url, provider: fileSystem, cancellation: cancellation)
    }

    /// A file on the local disk by what `stat` says of it (of the target, for a link): nil when
    /// it is a folder or cannot be asked about; throws for a pipe, a device or a socket.
    ///
    /// The entry of a link says nothing of its target's size (it is not the link's); the target is
    /// asked, so a link to a big file is not read to its end to count it.
    private static func localFile(_ url: URL, provider: any FileSystemProvider) throws -> (any ByteSource)? {
        var target = stat()
        guard stat(url.path, &target) == 0 else {
            return nil
        }
        switch target.st_mode & S_IFMT {
        case S_IFREG:
            return target.st_size > 0
                ? ProviderByteSource(url: url, provider: provider, length: Int64(target.st_size))
                : DataByteSource(Data())

        case S_IFDIR:
            return nil

        default:
            throw ViewerError.notAFile(url.lastPathComponent)
        }
    }

    /// A file of unknown size, read once to its end to count it: small content is simply kept,
    /// anything larger is only counted.
    private static func measure(
        _ url: URL,
        provider: any FileSystemProvider,
        cancellation: CancellationFlag
    ) throws -> any ByteSource {
        let reader = try provider.read(url, cancellation: cancellation)
        defer { reader.close() }
        var kept = Data()
        var total: Int64 = 0
        try cancellation.whileReading(reader) {
            while let block = try autoreleasepool(invoking: { try reader.read(upToCount: 1 << 20) }), !block.isEmpty {
                try cancellation.throwIfCancelled()
                total += Int64(block.count)
                // A stream that never ends (a device) is no file.
                guard total <= measuringLimit else { throw ViewerError.endless(url.lastPathComponent) }
                if total <= measuredKeepLimit { kept.append(block) } else { kept = Data() }
            }
        }
        try cancellation.throwIfCancelled()
        return total <= measuredKeepLimit
            ? DataByteSource(kept) : ProviderByteSource(url: url, provider: provider, length: total)
    }

    private static func reading(_ reader: any FileReader, _ flag: CancellationFlag?, _ body: () throws -> Void) throws {
        if let flag { try flag.whileReading(reader, body) } else { try body() }
    }

    /// The bytes from `offset` on, at most `count`; fewer only at the end of the file (blocks).
    internal func read(at offset: Int64, count: Int) throws -> Data {
        try read(at: offset, count: count, flag: nil)
    }

    /// `read(at:count:)`, interrupted (throwing) once `cancellation` is set.
    internal func read(at offset: Int64, count: Int, cancellation: CancellationFlag) throws -> Data {
        try read(at: offset, count: count, flag: cancellation)
    }

    /// Lets go of the idle readers, and of the ones in use as they come back.
    ///
    /// The readers are closed on a background queue: closing one may wait for the server, and
    /// `close` is called where nothing may wait (the main thread, as the file shown changes).
    internal func close() {
        lock.lock()
        let readers = idle
        idle = []
        closes += 1
        lock.unlock()
        ViewerCleanup.close(readers)
    }

    private func read(at offset: Int64, count: Int, flag: CancellationFlag?) throws -> Data {
        guard count > 0, offset < length else {
            return Data()
        }
        try flag?.throwIfCancelled()
        // The buffers a read leaves behind are freed at once: the threads that read live long.
        return try autoreleasepool {
            let (reader, epoch) = try checkOut(flag)
            var data = Data()
            do {
                try Self.reading(reader, flag) {
                    try reader.seek(to: UInt64(max(0, offset)))
                    let wanted = Int(min(Int64(count), length - offset))
                    while data.count < wanted, let block = try reader.read(upToCount: wanted - data.count),
                        !block.isEmpty
                    {
                        data.append(block)
                        try flag?.throwIfCancelled()
                    }
                }
            } catch {
                reader.close()
                throw error
            }
            // A reader the flag interrupted (or may still be about to) is of no use again.
            if flag?.isCancelled == true { reader.close() } else { checkIn(reader, epoch: epoch) }
            return data
        }
    }

    /// A reader and the number of `close`s there were when it was taken.
    private func checkOut(_ flag: CancellationFlag?) throws -> (any FileReader, Int) {
        lock.lock()
        let reader = idle.popLast()
        let epoch = closes
        lock.unlock()
        if let reader {
            return (reader, epoch)
        }
        return (try flag.map { try provider.read(url, cancellation: $0) } ?? provider.read(url), epoch)
    }

    private func checkIn(_ reader: any FileReader, epoch: Int) {
        lock.lock()
        // A reader that was in use when the source was closed is not kept: closing means it all.
        let keep = idle.count < idleLimit && epoch == closes
        if keep { idle.append(reader) }
        lock.unlock()
        if !keep { reader.close() }
    }

    deinit { ViewerCleanup.close(idle) }
}
