import AFMKernel
import Foundation

/// Bytes read from front to back: a part of a file, the output of a decompressor or of a
/// child process.
///
/// A stream belongs to the thread that reads it.
internal protocol ByteStream: AnyObject {
    /// The next block, never empty; nil at the end.
    func read(upToCount count: Int) throws -> Data?
    /// Passes over bytes without looking at them.
    func skip(_ count: UInt64) throws
    func close()
}

extension ByteStream {
    internal func skip(_ count: UInt64) throws {
        var left = count
        while left > 0 {
            guard let block = try read(upToCount: Int(min(left, 1 << 18))) else {
                throw ArchiveError.damaged("unexpected end of data")
            }
            left -= UInt64(block.count)
        }
    }

    /// Exactly `count` bytes, or fewer at the end of the stream.
    internal func readFully(_ count: Int) throws -> Data {
        var data = Data()
        while data.count < count, let block = try read(upToCount: count - data.count) { data.append(block) }
        return data
    }
}

/// Makes a system call that reads or writes, again for as long as a signal interrupts it
/// (`EINTR`); the count it returns, or -1 with `errno` set.
internal func retryingInterrupted(_ call: () -> Int) -> Int {
    var result: Int
    repeat {
        result = call()
    } while result < 0 && errno == EINTR
    return result
}

internal func posixError(_ code: Int32, _ path: String) -> any Error {
    NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(code),
        userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code)) + ": " + path]
    )
}

/// A file on the local disk that is read at any position, from any number of threads at once
/// (`pread` keeps no position).
///
/// The file stays readable for as long as this object lives, even when it is replaced or deleted
/// meanwhile.
internal final class RandomAccessFile: Sendable {
    internal let size: UInt64
    internal let path: String
    /// What the open file is, taken from the descriptor: a file that has since been replaced
    /// under the same path has another.
    internal let signature: FileSignature
    private let descriptor: Int32

    /// `shownAs` names the file in messages and to child processes when it is opened under a
    /// temporary name that it is about to lose.
    internal init(_ url: URL, shownAs: String? = nil) throws {
        path = shownAs ?? url.path
        descriptor = open(url.path, O_RDONLY)
        var status = stat()
        guard descriptor >= 0, fstat(descriptor, &status) == 0 else {
            let code = errno
            // (Closing -1, a file that did not open, does nothing.)
            Darwin.close(descriptor)
            throw posixError(code, path)
        }
        size = UInt64(status.st_size)
        signature = FileSignature(status)
    }

    deinit { Darwin.close(descriptor) }

    /// False when another file lies at the path now: a child process that opens the path
    /// would read that one.
    internal var isStillAtItsPath: Bool { FileSignature.of(path) == signature }

    /// Up to `count` bytes; fewer only at the end of the file.
    internal func read(at offset: UInt64, count: Int) throws -> Data {
        guard count > 0, offset < size else {
            return Data()
        }
        let wanted = Int(min(UInt64(count), size - offset))
        // Read straight into the block that is handed on: nothing is cleared first or copied after.
        guard let buffer = malloc(wanted) else { throw posixError(ENOMEM, path) }
        var done = 0
        while done < wanted {
            let got = retryingInterrupted {
                pread(descriptor, buffer + done, wanted - done, off_t(offset) + off_t(done))
            }
            if got < 0 {
                let code = errno
                free(buffer)
                throw posixError(code, path)
            }
            if got == 0 { break }
            done += got
        }
        guard done > 0 else {
            free(buffer)
            return Data()
        }
        return Data(bytesNoCopy: buffer, count: done, deallocator: .free)
    }
}

/// A request to end a read that runs through streams (decompressing, skipping on to a member,
/// waiting for a child process).
///
/// Set from any thread; the streams that can take long look at it and throw, and a child process is
/// stopped by it. All state is guarded by `lock`.
internal final class StreamInterrupt: @unchecked Sendable {
    private let lock = NSLock()
    private var isRaised = false
    private var handlers: [@Sendable () -> Void] = []

    internal var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRaised
    }

    internal func set() {
        lock.lock()
        let waiting = isRaised ? [] : handlers
        isRaised = true
        handlers = []
        lock.unlock()
        for handler in waiting { handler() }
    }

    internal func check() throws {
        if isSet { throw ArchiveError.cancelled }
    }

    /// Runs `handler` when the request is set, at once if it is already.
    ///
    /// Holds on to what it touches weakly.
    internal func onSet(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        guard isRaised else {
            handlers.append(handler)
            lock.unlock()
            return
        }
        lock.unlock()
        handler()
    }

    /// Set when `flag` is, for as long as the returned object is held.
    internal func following(_ flag: CancellationFlag?) -> AnyObject? {
        flag?.onCancel { [weak self] in self?.set() }
    }
}

/// Where the reader of a member hands the streams it reads through to its owner's request to
/// stop, which may come at any time from another thread.
///
/// A stream that is kept for the next reader (see `OpenArchive.park`) is let go of at `release()`,
/// so that a request that comes later cannot end somebody else's read. All state is guarded by
/// `lock`.
internal final class InterruptSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var interrupted = false
    private var current: StreamInterrupt?

    internal var isInterrupted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return interrupted
    }

    internal func interrupt() {
        lock.lock()
        interrupted = true
        // Under the lock: `release()` either comes before and this misses the chain, or after.
        current?.set()
        lock.unlock()
    }

    internal func use(_ control: StreamInterrupt?) {
        lock.lock()
        current = control
        if interrupted { control?.set() }
        lock.unlock()
    }

    internal func release() {
        lock.lock()
        current = nil
        lock.unlock()
    }
}

/// A stream that can continue at any position without reading what lies between.
internal protocol SeekableStream: ByteStream {
    /// `offset` counts from the first byte of the stream; past the end means the end.
    func seek(to offset: UInt64)
}

/// A stretch of a file as a stream; skipping costs nothing.
internal final class FileRangeStream: SeekableStream {
    private let file: RandomAccessFile
    private let start: UInt64
    private var position: UInt64
    private let end: UInt64

    /// A stretch that reaches past the end of the file (a damaged directory) ends with the file.
    internal init(_ file: RandomAccessFile, offset: UInt64 = 0, length: UInt64? = nil) {
        self.file = file
        let first = min(offset, file.size)
        start = first
        position = first
        end = length.map { min(file.size, first.plusClamped($0)) } ?? file.size
    }

    internal func seek(to offset: UInt64) {
        position = min(end, start.plusClamped(offset))
    }

    internal func read(upToCount count: Int) throws -> Data? {
        guard position < end else {
            return nil
        }
        let data = try file.read(at: position, count: Int(min(UInt64(count), end - position)))
        guard !data.isEmpty else {
            return nil
        }
        position += UInt64(data.count)
        return data
    }

    internal func skip(_ count: UInt64) throws {
        guard end - position >= count else { throw ArchiveError.damaged("unexpected end of data") }
        position += count
    }

    internal func close() {}
}

/// A stream that holds a few bytes in memory.
internal final class DataStream: SeekableStream {
    private let all: Data
    private var data: Data

    internal init(_ data: Data) {
        all = data
        self.data = data
    }

    internal func read(upToCount count: Int) -> Data? {
        guard !data.isEmpty else {
            return nil
        }
        let block = data.prefix(count)
        data = data.dropFirst(block.count)
        return Data(block)
    }

    internal func seek(to offset: UInt64) {
        data = all.dropFirst(Int(min(offset, UInt64(all.count))))
    }

    internal func close() {}
}

extension UInt64 {
    /// The sum, or the largest number when it does not fit: sizes read from a file may be anything.
    internal func plusClamped(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? .max : sum
    }
}

/// Lets through no more than a member is said to hold.
///
/// A member that unpacks to more than its directory entry declares is damaged or made to fill the
/// disk; it is stopped at the first byte too many instead of after the last.
internal final class SizeGuardStream: ByteStream {
    private let source: any ByteStream
    private var left: UInt64
    private let name: String

    internal init(_ source: any ByteStream, limit: UInt64, name: String) {
        self.source = source
        left = limit
        self.name = name
    }

    internal func read(upToCount count: Int) throws -> Data? {
        guard let block = try source.read(upToCount: count) else {
            return nil
        }
        guard UInt64(block.count) <= left else {
            throw ArchiveError.damaged("\(name) holds more data than its entry says")
        }
        left -= UInt64(block.count)
        return block
    }

    internal func close() { source.close() }
}

/// Passes a stream on and keeps a copy of what was read in a file, for as long as the copy
/// stays below `limit` (and the disk takes it).
///
/// Used by one thread.
internal final class TeeStream: ByteStream {
    private let source: any ByteStream
    private let output: OutputFile
    private let limit: UInt64
    /// False once the copy was given up; what the file holds is then worthless.
    internal private(set) var isComplete = true

    private let room: SpaceWatch?

    internal init(_ source: any ByteStream, to output: OutputFile, limit: UInt64, room: SpaceWatch? = nil) {
        self.source = source
        self.output = output
        self.limit = limit
        self.room = room
    }

    internal func read(upToCount count: Int) throws -> Data? {
        guard let block = try source.read(upToCount: count) else {
            return nil
        }
        if isComplete {
            if output.position.plusClamped(UInt64(block.count)) > limit || room?.allows(UInt64(block.count)) == false {
                isComplete = false
            } else {
                do { try output.write(block) } catch { isComplete = false }
            }
            // A copy that is given up frees its room now, not when the archive is let go.
            if !isComplete { output.discard() }
        }
        return block
    }

    internal func close() { source.close() }
}

/// A new file on the local disk, written from front to back, with the possibility to go back
/// and correct a header.
///
/// Used by one thread.
internal final class OutputFile {
    internal let url: URL
    private let descriptor: Int32
    private var buffer = Data()
    private var flushed: UInt64 = 0
    private var isClosed = false

    /// The file must not exist yet.
    ///
    /// It is the user's alone until whoever writes it says otherwise (`setMode`): a half-written
    /// archive is nobody else's to read.
    internal init(creating url: URL, mode: mode_t = 0o600) throws {
        self.url = url
        descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard descriptor >= 0 else {
            throw errno == EEXIST ? FileSystemError.alreadyExists(url.path) : posixError(errno, url.path)
        }
    }

    /// The rights of the file, whatever the process's mask says.
    internal func setMode(_ mode: mode_t) {
        if !isClosed { fchmod(descriptor, mode & 0o7777) }
    }

    /// Gives up what was written: the room it took is free at once, not when the file goes.
    internal func discard() {
        buffer.removeAll()
        if !isClosed { ftruncate(descriptor, 0) }
    }

    /// Continues an existing file at `offset`; what the file held from there on is cut off.
    internal init(extending url: URL, from offset: UInt64) throws {
        self.url = url
        // Opened without waiting and through no link, and looked at before anything is written:
        // whatever has taken the file's name meanwhile (a pipe, which would hold the open for
        // good or end the program at the first write to it, a link) is refused.
        descriptor = open(url.path, O_WRONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError(errno, url.path) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw posixError(EINVAL, url.path)
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) & ~O_NONBLOCK)
        guard let position = off_t(exactly: offset), ftruncate(descriptor, position) == 0,
            lseek(descriptor, position, SEEK_SET) >= 0
        else {
            let code = errno
            Darwin.close(descriptor)
            throw posixError(code, url.path)
        }
        flushed = offset
    }

    deinit {
        if !isClosed { Darwin.close(descriptor) }
    }

    /// Where the next byte goes.
    internal var position: UInt64 { flushed + UInt64(buffer.count) }

    internal func write(_ data: Data) throws {
        if data.count >= 1 << 16 {
            try flush()
            try writeOut(data, at: nil)
            flushed += UInt64(data.count)
        } else {
            buffer.append(data)
            if buffer.count >= 1 << 16 { try flush() }
        }
    }

    /// Replaces bytes that were written before.
    internal func rewrite(_ data: Data, at offset: UInt64) throws {
        try flush()
        try writeOut(data, at: offset)
    }

    private func flush() throws {
        guard !buffer.isEmpty else {
            return
        }
        try writeOut(buffer, at: nil)
        flushed += UInt64(buffer.count)
        buffer.removeAll(keepingCapacity: true)
    }

    private func writeOut(_ data: Data, at offset: UInt64?) throws {
        try data.withUnsafeBytes { bytes in
            var done = 0
            while done < bytes.count {
                let put = retryingInterrupted {
                    offset.map {
                        pwrite(descriptor, bytes.baseAddress! + done, bytes.count - done, off_t($0) + off_t(done))
                    }
                        ?? Darwin.write(descriptor, bytes.baseAddress! + done, bytes.count - done)
                }
                if put < 0 { throw posixError(errno, url.path) }
                done += put
            }
        }
    }

    /// `durably` returns only when the disk holds the data: for a file that is about to take
    /// the place of another, which a rename after a loss of power must not leave half-written.
    internal func close(durably: Bool = false) throws {
        guard !isClosed else {
            return
        }
        try flush()
        if durably, !Durable.sync(descriptor) {
            let code = errno
            isClosed = true
            Darwin.close(descriptor)
            throw posixError(code, url.path)
        }
        isClosed = true
        if Darwin.close(descriptor) != 0 { throw posixError(errno, url.path) }
    }
}

/// Makes writes last through a loss of power.
internal enum Durable {
    /// Waits until the file's data is on the disk, in order (`F_BARRIERFSYNC`: what the file
    /// system needs to keep a rename behind it honest, without emptying the drive's cache as
    /// `F_FULLFSYNC` does).
    ///
    /// File systems that do not know it get a plain `fsync`.
    internal static func sync(_ descriptor: Int32) -> Bool {
        if fcntl(descriptor, F_BARRIERFSYNC) == 0 {
            return true
        }
        return fsync(descriptor) == 0
    }

    /// After a rename: the folder's entry is what makes the new file the file.
    internal static func syncFolder(of url: URL) {
        let descriptor = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard descriptor >= 0 else {
            return
        }
        _ = fsync(descriptor)
        Darwin.close(descriptor)
    }

    /// Where a path leads once every symbolic link in it is followed: an archive that is
    /// reached through a link is rewritten where it really lies, and the link stays a link.
    internal static func realFile(_ url: URL) -> URL {
        guard let real = realpath(url.path, nil) else {
            return url
        }
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real), isDirectory: false)
    }
}

/// Little-endian numbers in a block of bytes, as ZIP stores them.
///
/// Reading past the end gives zero instead of a crash: the callers check signatures and lengths.
internal struct ByteReader {
    internal let data: Data
    internal var position = 0

    internal init(_ data: Data) {
        self.data = data
    }

    internal var remaining: Int { data.count - position }

    internal mutating func u8() -> UInt8 {
        guard remaining >= 1 else {
            position = data.count
            return 0
        }
        defer { position += 1 }
        return data[data.startIndex + position]
    }

    internal mutating func u16() -> UInt16 { UInt16(u8()) | UInt16(u8()) << 8 }
    internal mutating func u32() -> UInt32 { UInt32(u16()) | UInt32(u16()) << 16 }
    internal mutating func u64() -> UInt64 { UInt64(u32()) | UInt64(u32()) << 32 }

    internal mutating func bytes(_ count: Int) -> Data {
        let taken = max(0, min(count, remaining))
        defer { position += taken }
        return data.subdata(in: (data.startIndex + position)..<(data.startIndex + position + taken))
    }
}

extension Data {
    internal mutating func appendLE(_ value: UInt16) { append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)]) }
    internal mutating func appendLE(_ value: UInt32) {
        appendLE(UInt16(value & 0xFFFF))
        appendLE(UInt16(value >> 16))
    }
    internal mutating func appendLE(_ value: UInt64) {
        appendLE(UInt32(value & 0xFFFF_FFFF))
        appendLE(UInt32(value >> 32))
    }
}

/// Watches the room on a volume while something large is written to it: asked for every
/// block, it looks at the volume once per `step` bytes.
///
/// Used by one thread.
internal final class SpaceWatch {
    private let folder: URL
    private let reserve: UInt64
    private let hasRoom: (UInt64, URL) -> Bool
    private let step: UInt64
    private var sinceCheck: UInt64
    private var full = false

    /// `reserve` bytes stay free whatever is written.
    internal init(folder: URL, reserve: UInt64, step: UInt64 = 32 << 20, hasRoom: @escaping (UInt64, URL) -> Bool) {
        self.folder = folder
        self.reserve = reserve
        self.hasRoom = hasRoom
        self.step = step
        sinceCheck = 0
    }

    /// False once writing `count` more bytes would eat into the reserve.
    internal func allows(_ count: UInt64) -> Bool {
        guard !full else {
            return false
        }
        sinceCheck = sinceCheck.plusClamped(count)
        guard sinceCheck >= step else {
            return true
        }
        sinceCheck = 0
        full = !hasRoom(reserve.plusClamped(step), folder)
        return !full
    }
}

/// A folder for the plugin's temporary files: archives copied from other file systems, data
/// waiting to be written into an archive.
///
/// It is the user's alone (0700). Emptied when the plugin stops, and in any case when the program
/// exits; what a crash leaves behind is cleared away by the next start (`sweepLeftovers`). Safe to
/// use from any thread.
///
/// Temporary files that have to lie elsewhere (next to an archive on another volume) are
/// noted in a list beside the folder, so that they are found again and removed too.
///
/// Unchecked: what changes, here and in the table of all folders, is guarded by the static
/// `lock`.
internal final class ScratchFolder: @unchecked Sendable {
    internal let url: URL

    internal static let prefix = "afm-archives-"
    private static let keptMark = "kept-unsaved-changes"
    private static let lock = NSLock()
    /// Guarded by `lock`.
    nonisolated(unsafe) private static var folders: [String: ScratchFolder.Paths] = [:]
    private var isKept = false
    private var isMade = false
    private var externals: [String] = []

    private struct Paths {
        var externals: [String]
        var list: String
    }

    /// Registers the clean-up at exit once, for whatever folders exist by then.
    private static let atExit: Void = {
        _ = atexit {
            ScratchFolder.lock.lock()
            let all = ScratchFolder.folders
            ScratchFolder.lock.unlock()
            for (path, paths) in all {
                try? FileManager.default.removeItem(atPath: path)
                for external in paths.externals { ScratchFolder.removeExternal(external) }
                unlink(paths.list)
            }
        }
    }()

    internal init(in parent: URL = FileManager.default.temporaryDirectory) {
        url = parent.appendingPathComponent(
            "\(Self.prefix)\(getpid())-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private var listPath: String { url.path + ".external" }

    /// Makes the folder if it is not there.
    ///
    /// Any thread.
    private func prepare() throws {
        _ = Self.atExit
        Self.lock.lock()
        let (made, kept) = (isMade, isKept)
        if !kept { Self.folders[url.path] = Paths(externals: externals, list: listPath) }
        Self.lock.unlock()
        if made, FileManager.default.fileExists(atPath: url.path) {
            return
        }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        Self.lock.lock()
        isMade = true
        Self.lock.unlock()
    }

    internal func newFile(_ suffix: String = "tmp") throws -> URL {
        try prepare()
        return url.appendingPathComponent(UUID().uuidString + "." + suffix, isDirectory: false)
    }

    /// The names temporary things get outside the folder; nothing else is ever removed there.
    internal static func isOwnExternalName(_ name: String) -> Bool {
        name.hasPrefix(".")
            && (name.hasSuffix(".afm-zip.tmp") || name.hasSuffix(".afm-pack.tmp") || name.hasPrefix(".afm-spool-"))
    }

    private static func removeExternal(_ path: String) {
        guard isOwnExternalName((path as NSString).lastPathComponent) else {
            return
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Notes a temporary file or folder that lies outside this folder.
    ///
    /// It is removed with the folder if it is still there then, and by the next start if the
    /// program dies before.
    internal func noteExternal(_ url: URL) {
        guard Self.isOwnExternalName(url.lastPathComponent) else {
            return
        }
        try? prepare()
        Self.lock.lock()
        externals.append(url.path)
        if !isKept { Self.folders[self.url.path] = Paths(externals: externals, list: listPath) }
        Self.lock.unlock()
        // One short line appended; a list that cannot be written only means no sweep later.
        let descriptor = open(listPath, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            return
        }
        let line = Array((url.path + "\n").utf8)
        _ = line.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        Darwin.close(descriptor)
    }

    internal func removeAll() {
        Self.lock.lock()
        let (stays, outside) = (isKept, externals)
        if !stays {
            externals = []
            Self.folders[url.path] = nil
        }
        Self.lock.unlock()
        guard !stays else {
            return
        }
        try? FileManager.default.removeItem(at: url)
        for path in outside { Self.removeExternal(path) }
        unlink(listPath)
    }

    /// Leaves the folder on the disk, also when the program exits and when a later start
    /// clears away what crashes left: it holds data that could not be written where it belongs.
    internal func keep() {
        Self.lock.lock()
        isKept = true
        Self.folders.removeValue(forKey: url.path)
        Self.lock.unlock()
        unlink(listPath)
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        FileManager.default.createFile(
            atPath: url.appendingPathComponent(Self.keptMark).path,
            contents: Data()
        )
    }

    /// Removes the folders, and the temporary files noted outside them, of processes that no
    /// longer run: what a crash or a kill left behind.
    ///
    /// Folders that were kept on purpose stay. Touches the disk; meant for a background thread,
    /// once at the start.
    internal static func sweepLeftovers(in parent: URL = FileManager.default.temporaryDirectory) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else {
            return
        }
        for name in names where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count)
            guard let pid = pid_t(rest.prefix { $0 != "-" }), pid > 0, pid != getpid() else { continue }
            // Still running (or not ours to ask about): not touched.
            guard kill(pid, 0) != 0, errno == ESRCH else { continue }
            let path = parent.appendingPathComponent(name).path
            if name.hasSuffix(".external") {
                // Only while the folder it belongs to is not one that was kept.
                let folder = String(path.dropLast(".external".count))
                guard !FileManager.default.fileExists(atPath: folder + "/" + keptMark) else { continue }
                let listed = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                for line in listed.split(separator: "\n") { removeExternal(String(line)) }
                unlink(path)
            } else if !FileManager.default.fileExists(atPath: path + "/" + keptMark) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }
}

/// A temporary file that disappears with the last object that refers to it. `kept` is
/// guarded by `lock`.
internal final class TemporaryFile: @unchecked Sendable {
    internal let url: URL
    private let lock = NSLock()
    private var kept = false

    internal init(_ url: URL) {
        self.url = url
    }

    /// The file stays on the disk after all.
    internal func keep() {
        lock.lock()
        kept = true
        lock.unlock()
    }

    deinit {
        if !kept { unlink(url.path) }
    }
}
