import AFMKernel
import Darwin
import Foundation
import LocalFileSystemPlugin
import Testing

@testable import ViewerPlugin

/// The local copies of files of other file systems, for the players and Quick Look: refusals,
/// a disk that is full or fails, and what happens while a copy is made.
@Suite
internal struct CoverageViewerCopiesTests {
    private static let url = URL(string: "copy:///music/track.wav")!

    private static func folder() throws -> URL {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent(
            "afm-cov-copies-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        return made
    }

    private static func entry(_ url: URL, size: Int64) -> FileItem {
        FileItem(url: url, name: url.lastPathComponent, kind: .init(), stat: .init(size: size))
    }

    /// Takes no notice of a block.
    private static func ignore(_: Data) {
        // Nothing to do.
    }

    /// Does nothing.
    private static func nothing() {
        // Nothing to do.
    }

    /// A file system with one file of `data`, read with `hook` called for every block.
    private static func registry(
        _ data: Data,
        size: Int64?,
        mark: Data? = nil,
        hook: @escaping @Sendable (Data) -> Void = Self.ignore
    ) -> FileSystemRegistry {
        let provider = CoverageViewerProvider(
            scheme: "copy",
            mark: mark,
            entry: { url in size.map { Self.entry(url, size: $0) } },
            reader: { _ in CoverageViewerReader(data, onRead: hook, onClose: Self.nothing) }
        )
        let registry = provider.registry
        registry.register(LocalFileSystem())
        return registry
    }

    private static func disk(freeSpace: Int64? = nil, failing: Bool = false, limit: Int64 = 1 << 30)
        -> CopyDisk
    {
        var disk = CopyDisk.system
        if let freeSpace {
            disk.freeSpace = { _ in freeSpace }
        }
        if failing {
            disk.createFile = { _ in -1 }
        }
        disk.sizeLimit = limit
        return disk
    }

    // MARK: Refusals

    /// Each refusal says why, a cancellation says nothing.
    @Test
    internal func refusalsSayWhy() {
        #expect(TemporaryCopies.Refusal.cancelled.isCancelled && TemporaryCopies.Refusal.cancelled.message.isEmpty)
        let large = TemporaryCopies.Refusal.tooLarge(3 << 30, limit: 1 << 30)
        #expect(!large.isCancelled && large.message.contains("too large") && large.message.contains("limit"))
        #expect(TemporaryCopies.Refusal.noRoom.message.contains("free space"))
        #expect(TemporaryCopies.Refusal.unreadable.message == "The file cannot be shown in this mode.")
    }

    /// A local file is used as it is; a file of a file system that is not there cannot be copied.
    @Test
    internal func localFilesAreNotCopied() {
        let copies = TemporaryCopies()
        let local = URL(fileURLWithPath: "/tmp/file.txt")
        let registry = FileSystemRegistry()
        #expect(
            copies.localCopy(for: local, fileSystems: registry, cancellation: CancellationFlag()) == .success(local)
        )
        #expect(
            copies.localCopy(for: Self.url, fileSystems: registry, cancellation: CancellationFlag())
                == .failure(.unreadable)
        )
    }

    /// Changes that cannot be written first stop the copy; when the work was stopped meanwhile,
    /// that is what is said.
    @Test
    internal func changesThatCannotBeWrittenStopTheCopy() {
        let registry = Self.registry(Data("abc".utf8), size: 3)
        let flag = CancellationFlag()
        registry.addFlusher { _, cancellation in
            if cancellation === flag {
                cancellation.cancel()
            }
            throw CocoaError(.fileWriteUnknown)
        }
        let copies = TemporaryCopies()
        #expect(
            copies.localCopy(for: Self.url, fileSystems: registry, cancellation: CancellationFlag())
                == .failure(.unreadable)
        )
        #expect(copies.localCopy(for: Self.url, fileSystems: registry, cancellation: flag) == .failure(.cancelled))
    }

    /// A file that cannot be opened is refused, or the copy counts as stopped when its flag was set.
    @Test
    internal func aFileThatCannotBeOpenedIsRefused() {
        let flag = CancellationFlag()
        let provider = CoverageViewerProvider(
            scheme: "copy",
            entry: { Self.entry($0, size: 3) },
            reader: { _ in
                throw CocoaError(.fileReadNoPermission)
            }
        )
        let copies = TemporaryCopies()
        #expect(
            copies.localCopy(for: Self.url, fileSystems: provider.registry, cancellation: CancellationFlag())
                == .failure(.unreadable)
        )
        let stopping = CoverageViewerProvider(
            scheme: "copy",
            entry: { Self.entry($0, size: 3) },
            reader: { _ in
                flag.cancel()
                throw CocoaError(.userCancelled)
            }
        )
        #expect(
            copies.localCopy(for: Self.url, fileSystems: stopping.registry, cancellation: flag) == .failure(.cancelled)
        )
    }

    /// Without a folder for copies, a full disk, or a file that cannot be made, nothing is copied.
    @Test
    internal func aDiskThatCannotTakeTheCopyRefusesIt() throws {
        let readOnly = try Self.folder()
        defer {
            chmod(readOnly.path, 0o700)
            try? FileManager.default.removeItem(at: readOnly)
        }
        #expect(chmod(readOnly.path, 0o500) == 0)
        let registry = Self.registry(Data("abc".utf8), size: 3)
        let flag = CancellationFlag()
        #expect(
            TemporaryCopies(directory: readOnly).localCopy(for: Self.url, fileSystems: registry, cancellation: flag)
                == .failure(.unreadable)
        )
        let full = TemporaryCopies(directory: FileManager.default.temporaryDirectory, disk: Self.disk(freeSpace: 0))
        #expect(full.localCopy(for: Self.url, fileSystems: registry, cancellation: flag) == .failure(.noRoom))
        let failing = TemporaryCopies(directory: FileManager.default.temporaryDirectory, disk: Self.disk(failing: true))
        #expect(failing.localCopy(for: Self.url, fileSystems: registry, cancellation: flag) == .failure(.unreadable))
        #expect(CopyDisk.freeSpace(of: readOnly.appendingPathComponent("missing")) == nil)
        #expect((CopyDisk.freeSpace(of: readOnly) ?? 0) > 0)
    }

    /// The folder of one copy that cannot be made refuses that copy.
    @Test
    internal func aCopyWhoseFolderCannotBeMadeIsRefused() throws {
        let registry = Self.registry(Data("abc".utf8), size: 3)
        let copies = TemporaryCopies()
        let first = try copies.localCopy(for: Self.url, fileSystems: registry, cancellation: CancellationFlag()).get()
        let root = first.deletingLastPathComponent().deletingLastPathComponent()
        #expect(chmod(root.path, 0o500) == 0)
        defer { chmod(root.path, 0o700) }
        let other = try #require(URL(string: "copy:///music/other.wav"))
        #expect(
            copies.localCopy(for: other, fileSystems: registry, cancellation: CancellationFlag())
                == .failure(.unreadable)
        )
    }

    // MARK: While copying

    /// A copy that is stopped while it reads, that turns out bigger than the limit, or whose
    /// file fails, is not kept.
    @Test
    internal func copiesThatFailWhileReadingAreNotKept() {
        let flag = CancellationFlag()
        let stopped = Self.registry(Data("abc".utf8), size: 3) { _ in flag.cancel() }
        let copies = TemporaryCopies(directory: FileManager.default.temporaryDirectory, disk: Self.disk(limit: 10))
        #expect(copies.localCopy(for: Self.url, fileSystems: stopped, cancellation: flag) == .failure(.cancelled))
        let unknownSize = Self.registry(Data(count: 20), size: nil)
        #expect(
            copies.localCopy(for: Self.url, fileSystems: unknownSize, cancellation: CancellationFlag())
                == .failure(.tooLarge(20, limit: 10))
        )
        let provider = CoverageViewerProvider(
            scheme: "copy",
            entry: { Self.entry($0, size: 3) },
            reader: { _ in CoverageViewerBrokenReader() }
        )
        #expect(
            copies.localCopy(for: Self.url, fileSystems: provider.registry, cancellation: CancellationFlag())
                == .failure(.unreadable)
        )
    }

    /// The copy of a file that came from elsewhere carries the same quarantine mark.
    @Test
    internal func theQuarantineMarkIsKept() throws {
        let mark = Data("0081;00000000;Test;".utf8)
        let registry = Self.registry(Data("abc".utf8), size: 3, mark: mark)
        let copies = TemporaryCopies()
        let copy = try copies.localCopy(for: Self.url, fileSystems: registry, cancellation: CancellationFlag()).get()
        var buffer = [UInt8](repeating: 0, count: 256)
        let length = getxattr(copy.path, "com.apple.quarantine", &buffer, buffer.count, 0, 0)
        #expect(length > 0)
        #expect(String(bytes: buffer.prefix(max(0, length)), encoding: .utf8)?.hasPrefix("0081;") == true)
    }

    /// When all copies are deleted while one is made, that one is not kept.
    @Test
    internal func aCopyMadeWhileAllAreDeletedIsNotKept() {
        let holder = ViewerAdoptBox<TemporaryCopies?>(nil)
        let registry = Self.registry(Data("abc".utf8), size: 3) { block in
            if !block.isEmpty {
                holder.value?.removeAll(waiting: false)
            }
        }
        let copies = TemporaryCopies()
        holder.value = copies
        #expect(
            copies.localCopy(for: Self.url, fileSystems: registry, cancellation: CancellationFlag())
                == .failure(.cancelled)
        )
        holder.value = nil
    }

    /// When the same file was copied meanwhile, that copy is used and the second is dropped.
    @Test
    internal func aFileCopiedMeanwhileIsUsedOnce() throws {
        let holder = ViewerAdoptBox<TemporaryCopies?>(nil)
        let nested = ViewerAdoptBox<URL?>(nil)
        let started = ViewerAdoptBox(false)
        let registryBox = ViewerAdoptBox<FileSystemRegistry?>(nil)
        let registry = Self.registry(Data("abc".utf8), size: 3) { block in
            guard !block.isEmpty, !started.value, let copies = holder.value, let registry = registryBox.value else {
                return
            }
            started.value = true
            nested.value = try? copies.localCopy(for: Self.url, fileSystems: registry, cancellation: CancellationFlag())
                .get()
        }
        registryBox.value = registry
        let copies = TemporaryCopies()
        holder.value = copies
        let outer = try copies.localCopy(for: Self.url, fileSystems: registry, cancellation: CancellationFlag()).get()
        #expect(nested.value == outer)
        #expect(FileManager.default.fileExists(atPath: outer.path))
        holder.value = nil
        registryBox.value = nil
    }

    /// A copy whose owner let go of its copies while it was made is kept as an idle one: the
    /// newer idle copies push it out.
    @Test
    internal func aCopyReleasedWhileMadeIsIdle() throws {
        let holder = ViewerAdoptBox<TemporaryCopies?>(nil)
        let owner = ObjectIdentifier(Self.self)
        let other = ObjectIdentifier(NSObject.self)
        let releasing = Self.registry(Data("abc".utf8), size: 3) { block in
            if !block.isEmpty {
                holder.value?.release(owner: owner)
            }
        }
        let copies = TemporaryCopies()
        holder.value = copies
        let first =
            try copies.localCopy(for: Self.url, fileSystems: releasing, owner: owner, cancellation: CancellationFlag())
            .get()
        holder.value = nil
        let plain = Self.registry(Data("abc".utf8), size: 3)
        for name in ["a", "b", "c"] {
            let track = try #require(URL(string: "copy:///music/\(name).wav"))
            _ = copies.localCopy(for: track, fileSystems: plain, owner: other, cancellation: CancellationFlag())
        }
        copies.release(owner: other)
        copies.waitForCleanup()
        #expect(!FileManager.default.fileExists(atPath: first.path))
    }

    /// Sweeping a folder that is not there does nothing.
    @Test
    internal func sweepingAMissingFolderDoesNothing() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(
            "afm-cov-missing-\(UUID().uuidString)"
        )
        TemporaryCopies.sweep(in: missing)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
}
