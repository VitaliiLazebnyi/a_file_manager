import AFMKernel
import Darwin
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import ViewerPlugin

/// Review round 2, the sources of bytes: opening links and special files, closing readers off the
/// calling thread, saving, the copies for the players, and the rules for links in a viewed file.
@Suite
internal struct Review2ViewerSourceTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "afm-r2viewer-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func local() -> FileSystemRegistry {
        let registry = FileSystemRegistry()
        registry.register(LocalFileSystem())
        return registry
    }

    // MARK: Opening

    /// A symbolic link to a file is opened with the size of its target, an empty one as empty.
    @Test
    internal func aLinkToAFileIsOpenedWithTheSizeOfItsTarget() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.log")
        try Data(repeating: UInt8(ascii: "x"), count: 5_000).write(to: target)
        let link = directory.appendingPathComponent("current.log")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let source = try ProviderByteSource.open(link, fileSystems: local(), cancellation: CancellationFlag())
        #expect(source is ProviderByteSource && source.length == 5_000)
        #expect(try source.read(at: 4_990, count: 100).count == 10)
        // An empty file is empty, through a link too.
        let empty = directory.appendingPathComponent("empty")
        try Data().write(to: empty)
        let emptyLink = directory.appendingPathComponent("empty-link")
        try FileManager.default.createSymbolicLink(at: emptyLink, withDestinationURL: empty)
        #expect(
            try ProviderByteSource.open(emptyLink, fileSystems: local(), cancellation: CancellationFlag()).length == 0
        )
        #expect(try ProviderByteSource.open(empty, fileSystems: local(), cancellation: CancellationFlag()).length == 0)
    }

    /// Devices, links to them and pipes are refused without being read; a pipe does not block the open.
    @Test
    internal func devicesAndPipesAreRefusedWithoutBeingRead() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        for path in ["/dev/zero", "/dev/null"] {
            #expect(throws: ViewerError.self) {
                try ProviderByteSource.open(
                    URL(fileURLWithPath: path),
                    fileSystems: local(),
                    cancellation: CancellationFlag()
                )
            }
        }
        let zero = directory.appendingPathComponent("zero-link")
        try FileManager.default.createSymbolicLink(at: zero, withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        #expect(throws: ViewerError.self) {
            try ProviderByteSource.open(zero, fileSystems: local(), cancellation: CancellationFlag())
        }
        // A FIFO would block on open() forever.
        let fifo = directory.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let outcome = ViewerAdoptBox<Bool>(false)
        let worker = ViewerAdoptWorker {
            outcome.value =
                (try? ProviderByteSource.open(fifo, fileSystems: local(), cancellation: CancellationFlag())) == nil
        }
        worker.start()
        #expect(worker.waitUntilFinished() && outcome.value)
    }

    /// Measuring a file that never ends stops when its cancellation flag is set.
    @Test
    internal func measuringAFileOfUnknownSizeStopsWithItsFlag() throws {
        let stream = try #require(URL(string: "hook:///stream"))
        let provider = Review2HookProvider()
        provider.endless = ["/stream"]
        let registry = FileSystemRegistry()
        registry.register(provider)
        let flag = CancellationFlag()
        let outcome = ViewerAdoptBox<Result<any ByteSource, any Error>?>(nil)
        let worker = ViewerAdoptWorker {
            outcome.value = Result {
                try ProviderByteSource.open(stream, fileSystems: registry, cancellation: flag)
            }
        }
        worker.start()
        usleep(30_000)
        flag.cancel()
        #expect(worker.waitUntilFinished())
        if case .success? = outcome.value { Issue.record("The stream was opened") }
    }

    /// An entry its file system calls special is refused, whatever file system it is on.
    @Test
    internal func specialEntriesAreRefusedWhateverTheFileSystem() throws {
        let stream = try #require(URL(string: "hook:///stream"))
        let provider = Review2HookProvider()
        provider.endless = ["/stream"]
        provider.special = ["/stream"]
        let registry = FileSystemRegistry()
        registry.register(provider)
        #expect(throws: ViewerError.self) {
            try ProviderByteSource.open(stream, fileSystems: registry, cancellation: CancellationFlag())
        }
    }

    // MARK: Closing

    /// Closing a source returns while its readers' closes are still blocked, and they are closed later.
    @Test
    internal func closingTheSourceDoesNotWaitForTheReaders() throws {
        let file = try #require(URL(string: "hook:///a"))
        let provider = Review2HookProvider()
        provider.contents["/a"] = Data(repeating: 0x42, count: 100_000)
        let registry = FileSystemRegistry()
        registry.register(provider)
        let gate = DispatchSemaphore(value: 0)
        provider.onClose = { _ = gate.wait(timeout: .now() + Wait.ceiling) }
        let source = try ProviderByteSource.open(file, fileSystems: registry, cancellation: CancellationFlag())
        _ = try source.read(at: 0, count: 10)
        // The close of the reader blocks (a server that does not answer): `close` returns anyway.
        let started = Date()
        source.close()
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(provider.closeCount == 0)
        gate.signal()
        ViewerCleanup.drain()
        #expect(provider.closeCount == 1)
    }

    /// A reader that was in use when the source closed is closed when it comes back; letting go of a
    /// source closes its readers.
    @Test
    internal func aReaderInUseWhenTheSourceIsClosedIsClosedWhenItComesBack() throws {
        let file = try #require(URL(string: "hook:///a"))
        let provider = Review2HookProvider()
        provider.contents["/a"] = Data(repeating: 0x42, count: 100_000)
        let registry = FileSystemRegistry()
        registry.register(provider)
        let source = try ProviderByteSource.open(file, fileSystems: registry, cancellation: CancellationFlag())
        // Two readers: one idle, one that was out when `close` came.
        _ = try source.read(at: 0, count: 10)
        source.close()
        ViewerCleanup.drain()
        #expect(provider.closeCount == 1)
        _ = try source.read(at: 0, count: 10)
        source.close()
        ViewerCleanup.drain()
        #expect(provider.closeCount == 2)
        // Letting go of the source closes what it holds, off the thread that lets go.
        var again: ProviderByteSource? = try #require(
            try ProviderByteSource.open(file, fileSystems: registry, cancellation: CancellationFlag())
                as? ProviderByteSource
        )
        _ = try again?.read(at: 0, count: 10)
        again = nil
        ViewerCleanup.drain()
        #expect(provider.closeCount == 3)
    }

    // MARK: The block cache

    /// A block that was read short is not kept: the next read asks for it again.
    @Test
    internal func aShortBlockIsNotKeptInMemory() throws {
        // Unchecked: its switches are set by the test before use, and it is used from one thread at a time.
        final class Flaky: ByteSource, @unchecked Sendable {
            let length: Int64 = 40_000
            var short = true

            func read(at offset: Int64, count: Int) -> Data {
                let wanted = min(count, 40_000 - Int(offset))
                return Data(repeating: 0x61, count: short ? wanted / 2 : wanted)
            }

            deinit {
                // Nothing to release.
            }
        }
        let base = Flaky()
        let cached = CachedByteSource(
            base,
            policy: CachedByteSource.Policy(
                blockSize: 4_096,
                capacity: 8,
                wholeFileLimit: 0,
                spillsToDisk: false,
                diskLimit: 1 << 30
            )
        )
        // A read that came back short ...
        #expect(try cached.read(at: 0, count: 100).count == 100)
        base.short = false
        // ... is not remembered: the next one asks again and gets the whole block.
        #expect(try cached.read(at: 0, count: 4_096).count == 4_096)
        #expect(try cached.read(at: 0, count: 4_096).count == 4_096)
    }

    /// A read of four blocks or more passes the block cache, and later reads still work.
    @Test
    internal func aLongReadOfFourBlocksGoesPastTheMemoryCache() throws {
        let data = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0) })
        let cached = CachedByteSource(
            DataByteSource(data),
            policy: CachedByteSource.Policy(
                blockSize: 256 << 10,
                capacity: 4,
                wholeFileLimit: 0,
                spillsToDisk: false,
                diskLimit: 1 << 30
            )
        )
        _ = try cached.read(at: 0, count: 1 << 20)
        // Four blocks of 256 KB are a scan: nothing was kept, a read of one block still works.
        #expect(try cached.read(at: 300_000, count: 100) == data.subdata(in: 300_000..<300_100))
    }

    // MARK: Save as

    /// The viewed file is recognised as the target of a save through links, hard links and other spellings.
    @Test
    internal func savingOntoTheViewedFileIsRecognisedAndRefused() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a.txt")
        try Data("content".utf8).write(to: file)
        let link = directory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let hard = directory.appendingPathComponent("hard.txt")
        try FileManager.default.linkItem(at: file, to: hard)
        #expect(
            ViewerSave.isSameFile(file, file) && ViewerSave.isSameFile(file, link) && ViewerSave.isSameFile(link, file)
                && ViewerSave.isSameFile(file, hard)
        )
        #expect(
            !ViewerSave.isSameFile(file, directory.appendingPathComponent("other.txt"))
                && !ViewerSave.isSameFile(nil, file)
        )
        // A target that does not exist yet, spelled differently.
        #expect(ViewerSave.isSameFile(directory.appendingPathComponent("x/../a.txt"), file))
    }

    /// A save writes a temporary file, reports its progress, and leaves only the target behind.
    @Test
    internal func aSaveWritesATemporaryFileAndMovesItIntoPlace() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("copy.bin")
        try Data("old".utf8).write(to: target)
        let data = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        var last: Int64 = 0
        try ViewerSave.save(DataByteSource(data), to: target, cancellation: CancellationFlag()) { last = $0 }
        #expect(try Data(contentsOf: target) == data && last == Int64(data.count))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["copy.bin"])
    }

    /// A save of a file that became shorter, or a cancelled one, fails and leaves the target as it was.
    @Test
    internal func aSaveOfAFileThatBecameShorterFailsAndLeavesTheTargetAlone() throws {
        final class Short: ByteSource {
            let length: Int64 = 2_000_000

            func read(at offset: Int64, count: Int) -> Data {
                offset >= 1_500_000 ? Data() : Data(repeating: 0x42, count: min(count, 1_500_000 - Int(offset)))
            }

            deinit {
                // Nothing to release.
            }
        }
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("copy.bin")
        try Data("old".utf8).write(to: target)
        #expect(throws: ViewerError.fileChanged) {
            try ViewerSave.save(Short(), to: target, cancellation: CancellationFlag()) { _ in
                // Not watched here.
            }
        }
        #expect(try Data(contentsOf: target) == Data("old".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["copy.bin"])
        // Cancelled: the same.
        let flag = CancellationFlag()
        flag.cancel()
        #expect(throws: (any Error).self) {
            try ViewerSave.save(DataByteSource(Data(count: 100)), to: target, cancellation: flag) { _ in
                // Not watched here.
            }
        }
        #expect(try Data(contentsOf: target) == Data("old".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["copy.bin"])
    }
}
