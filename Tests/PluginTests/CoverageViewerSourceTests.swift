import AFMKernel
import Darwin
import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin

/// Where the viewer's bytes come from: opening files through their file systems, the readers
/// kept between reads, the blocks kept in memory and on disk, and where characters begin.
@Suite
internal struct CoverageViewerSourceTests {
    private static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "afm-cov-viewer-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func entry(_ url: URL, size: Int64 = 0, directory: Bool = false) -> FileItem {
        FileItem(url: url, name: url.lastPathComponent, kind: .init(isDirectory: directory), stat: .init(size: size))
    }

    // MARK: Errors

    /// Each error says what happened, naming the file where there is one.
    @Test
    internal func everyErrorExplainsItself() {
        #expect(ViewerError.fileChanged.errorDescription?.contains("became shorter") == true)
        #expect(ViewerError.notAFile("pipe").errorDescription?.hasPrefix("pipe is not a regular file") == true)
        #expect(ViewerError.endless("zero").errorDescription == "zero does not end, and cannot be shown.")
        #expect(ViewerError.busy.errorDescription?.contains("does not answer") == true)
    }

    // MARK: Opening

    /// A piece cut out of other data is read from its own first byte.
    @Test
    internal func aSliceIsReadFromItsOwnStart() {
        let whole = Data([10, 11, 12, 13, 14])
        let source = DataByteSource(whole[2...])
        #expect(source.length == 3)
        #expect(source.read(at: 0, count: 10) == Data([12, 13, 14]))
    }

    /// A local file whose entry tells no size is measured by asking the disk, not by reading it.
    @Test
    internal func aLocalFileWithoutASizeInItsEntryIsMeasuredOnDisk() throws {
        let directory = try Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("grown.log")
        try Data(repeating: 0x61, count: 4_000).write(to: file)
        let reads = ViewerAdoptBox(0)
        let provider = CoverageViewerProvider(
            scheme: "file",
            entry: { Self.entry($0) },
            reader: { url in
                reads.mutate { $0 += 1 }
                return CoverageViewerReader(try Data(contentsOf: url))
            }
        )
        let source = try ProviderByteSource.open(file, fileSystems: provider.registry)
        #expect(source is ProviderByteSource && source.length == 4_000)
        #expect(reads.value == 0)
        #expect(try source.read(at: 3_990, count: 100) == Data(repeating: 0x61, count: 10))
    }

    /// Without an entry, the disk tells what the path is: a pipe is refused, a missing file is
    /// an error of its file system, and a folder is left to its file system to read.
    @Test
    internal func withoutAnEntryTheDiskTellsWhatThePathIs() throws {
        let directory = try Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let provider = CoverageViewerProvider(
            scheme: "file",
            entry: { _ in nil },
            reader: { url in
                guard url.lastPathComponent != "missing" else { throw CocoaError(.fileReadNoSuchFile) }
                return CoverageViewerReader(Data("listing".utf8))
            }
        )
        #expect(throws: ViewerError.notAFile("pipe")) {
            try ProviderByteSource.open(fifo, fileSystems: provider.registry)
        }
        #expect(throws: CocoaError.self) {
            try ProviderByteSource.open(directory.appendingPathComponent("missing"), fileSystems: provider.registry)
        }
        let folder = try ProviderByteSource.open(directory, fileSystems: provider.registry)
        #expect(folder is DataByteSource && folder.length == 7)
    }

    /// A file of unknown size elsewhere is read once to count it: a small one is kept, a big one
    /// is read again where it is shown.
    @Test
    internal func aFileOfUnknownSizeIsCountedByReadingIt() throws {
        let small = Data("short note".utf8)
        let big = Data(repeating: 0x62, count: (16 << 20) + 5)
        let provider = CoverageViewerProvider(
            scheme: "count",
            entry: { Self.entry($0) },
            reader: { url in
                CoverageViewerReader(url.lastPathComponent == "small" ? small : big)
            }
        )
        let first = try ProviderByteSource.open(
            try #require(URL(string: "count:///small")),
            fileSystems: provider.registry
        )
        #expect(first is DataByteSource && first.length == Int64(small.count))
        #expect(try first.read(at: 0, count: 5) == Data("short".utf8))
        let second = try ProviderByteSource.open(
            try #require(URL(string: "count:///big")),
            fileSystems: provider.registry
        )
        #expect(second is ProviderByteSource && second.length == Int64(big.count))
        #expect(try second.read(at: Int64(big.count) - 3, count: 10) == Data(repeating: 0x62, count: 3))
    }

    /// A stream without an end is refused once more than a file can hold has come out of it.
    @Test
    internal func aStreamThatNeverEndsIsRefused() throws {
        let provider = CoverageViewerProvider(
            scheme: "stream",
            entry: { _ in nil },
            reader: { _ in
                CoverageViewerEndlessReader()
            }
        )
        let url = try #require(URL(string: "stream:///random"))
        #expect(throws: ViewerError.endless("random")) {
            try ProviderByteSource.open(url, fileSystems: provider.registry)
        }
    }

    // MARK: Readers

    /// A reader whose read was ended by its flag is closed, not kept for the next read.
    @Test
    internal func aReaderEndedByItsFlagIsNotKept() throws {
        let data = Data(repeating: 0x63, count: 100)
        let flag = CancellationFlag()
        let opened = ViewerAdoptBox(0)
        let closed = ViewerAdoptBox(0)
        // The entry tells more than there is: the reader comes to its end before the read is done.
        let provider = CoverageViewerProvider(
            scheme: "flag",
            entry: { Self.entry($0, size: 200) },
            reader: { _ in
                opened.mutate { $0 += 1 }
                // The flag is set as the reader reaches the end, which ends the read without an error.
                return CoverageViewerReader(
                    data,
                    onRead: { block in
                        if block.isEmpty { flag.cancel() }
                    },
                    onClose: { closed.mutate { $0 += 1 } }
                )
            }
        )
        let source = try ProviderByteSource.open(try #require(URL(string: "flag:///a")), fileSystems: provider.registry)
        #expect(try source.read(at: 90, count: 50, cancellation: flag) == Data(repeating: 0x63, count: 10))
        #expect(closed.value == 1)
        #expect(try source.read(at: 0, count: 10) == Data(repeating: 0x63, count: 10))
        #expect(opened.value == 2)
    }

    /// A reader that was in use while the source was closed is closed as it comes back.
    @Test
    internal func aReaderInUseWhileTheSourceIsClosedIsClosedOnItsReturn() throws {
        let data = Data(repeating: 0x64, count: 100)
        let holder = ViewerAdoptBox<(any ByteSource)?>(nil)
        let closed = ViewerAdoptBox(0)
        let provider = CoverageViewerProvider(
            scheme: "epoch",
            entry: { Self.entry($0, size: 100) },
            reader: { _ in
                CoverageViewerReader(
                    data,
                    onRead: { _ in holder.value?.close() },
                    onClose: { closed.mutate { $0 += 1 } }
                )
            }
        )
        let source = try ProviderByteSource.open(
            try #require(URL(string: "epoch:///a")),
            fileSystems: provider.registry
        )
        holder.value = source
        #expect(try source.read(at: 0, count: 10).count == 10)
        holder.value = nil
        #expect(closed.value == 1)
    }

    // MARK: Character boundaries

    /// The boundaries kept are bounded: past the limit, all but the start are let go, and
    /// the next ones are found again from there.
    @Test
    internal func theBoundariesKeptAreLimited() throws {
        let limit = CharacterBoundaries.keptLimit
        let text = Data(repeating: 0x41, count: 16 * (limit + 2))
        let encoding = try #require(ViewerEncoding.codePage(932))
        let boundaries = CharacterBoundaries(
            source: DataByteSource(text),
            content: 0..<Int64(text.count),
            encoding: encoding,
            spacing: 16
        )
        for block in 1..<limit {
            #expect(try boundaries.characterStart(atOrBefore: Int64(block * 16 + 3)) == Int64(block * 16 + 3))
        }
        #expect(boundaries.blockCount == limit)
        #expect(try boundaries.characterStart(atOrBefore: Int64(limit * 16)) == Int64(limit * 16))
        #expect(boundaries.blockCount == 2)
        #expect(try boundaries.characterStart(atOrBefore: Int64(limit * 16 + 20)) == Int64(limit * 16 + 20))
    }

    // MARK: Saving

    /// A folder that cannot be written to is reported, and nothing is left in it.
    @Test
    internal func savingIntoAFolderWithoutPermissionFails() throws {
        let directory = try Self.folder()
        defer {
            chmod(directory.path, 0o700)
            try? FileManager.default.removeItem(at: directory)
        }
        #expect(chmod(directory.path, 0o500) == 0)
        let target = directory.appendingPathComponent("copy.txt")
        let error = #expect(throws: CocoaError.self) {
            try ViewerSave.save(DataByteSource(Data("text".utf8)), to: target, cancellation: CancellationFlag())
        }
        #expect(error?.code == .fileWriteNoPermission)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    /// A target that cannot be replaced (a folder with files in it) is reported, and the new
    /// file written beside it is removed.
    @Test
    internal func savingOntoAFolderFailsAndLeavesNothing() throws {
        let directory = try Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("taken")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data().write(to: target.appendingPathComponent("inside"))
        #expect(throws: CocoaError.self) {
            try ViewerSave.save(DataByteSource(Data("text".utf8)), to: target, cancellation: CancellationFlag())
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["taken"])
    }

    // MARK: Work gate

    /// A job refused by a gate that is stuck, without anything to call instead, simply does not run.
    @Test
    internal func aRefusedJobWithoutAHandlerIsDropped() {
        let gate = ViewerWorkGate(live: 1, stuck: 1)
        let release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let flag = CancellationFlag()
        gate.submit(cancellation: flag) {
            started.signal()
            _ = release.wait(timeout: .now() + 60)
        }
        #expect(started.wait(timeout: .now() + 60) == .success)
        flag.cancel()
        let ran = ViewerAdoptBox(false)
        gate.submit(cancellation: CancellationFlag()) { ran.value = true }
        #expect(gate.waitingCount == 0 && gate.threadsInUse == 1)
        release.signal()
        #expect(Wait.until { gate.threadsInUse == 0 })
        #expect(!ran.value)
    }
}
