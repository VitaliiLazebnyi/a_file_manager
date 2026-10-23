import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Pack into archives that are not on the local disk (a server played by a memory file
/// system), and the compression of large members across windows.
@Suite
internal struct CoverageArchivesFormatsPackElsewhere {
    private let bench: ArchiveBench
    private var box: Sandbox { bench.box }

    /// A new bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    private func run(_ sources: [URL], to archive: URL, monitor: any JobMonitor, format: ArchiveFormat = .zip) throws
        -> PackResult
    {
        var options = PackOptions()
        options.format = format
        let packer = Packer(fileSystems: bench.fileSystems, store: bench.store, monitor: monitor, options: options)
        return packer.run(try sources.map(bench.item), archive: archive, innerFolder: "")
    }

    /// An archive the store lets go just before the first change is asked for again, and takes the members.
    @Test
    internal func anArchiveLetGoBeforeTheFirstChangeIsAskedForAgain() throws {
        let archive = bench.memory.url("server.zip")
        try bench.pack([try box.file("first.txt")], to: archive)
        let monitor = CoverageArchivesFormatsMonitor()
        let retired = SharedCounter()
        let store = bench.store
        monitor.whenAsked {
            guard retired.value == 0, let open = store.openArchive(at: archive), open.retireIfIdle() else {
                return
            }
            retired.add(1)
        }
        let result = try run([try box.file("second.txt")], to: archive, monitor: monitor)
        #expect(result.failure == nil && retired.value == 1)
        #expect(try bench.names(bench.inside(archive)) == ["first.txt", "second.txt"])
    }

    /// A member that cannot take its name in the archive is taken out again, and the reason given.
    @Test
    internal func aMemberThatCannotTakeItsNameIsTakenOutAgain() throws {
        let archive = bench.memory.url("server.zip")
        try box.file("x/inside.txt")
        try bench.pack([box.url("x")], to: archive)
        try FileManager.default.removeItem(at: box.url("x"))
        let result = try run([try box.file("x", "a file now")], to: archive, monitor: bench.monitor)
        #expect(result.failure?.localizedDescription == FileSystemError.alreadyExists("x").errorDescription)
        #expect(try bench.names(bench.inside(archive)) == ["x"])
        #expect(try bench.names(bench.inside(archive, "x")) == ["inside.txt"])
    }

    /// A new archive whose sending to the server is cancelled leaves nothing there.
    @Test
    internal func anArchiveWhoseSendingIsCancelledLeavesNothing() throws {
        let source = try box.file("sent.txt", "sent")
        let archive = bench.memory.url("folder/sent.tar")
        bench.memory.stallsWrites = true
        defer { bench.memory.releaseStalls() }
        let done = Signal<Bool>()
        OtherThread.start {
            let result = try? run([source], to: archive, monitor: bench.monitor, format: .tar)
            done.set(result?.failure != nil || result?.cancelled == true)
        }
        #expect(Wait.until { bench.memory.stalledTransfers > 0 })
        bench.monitor.cancellation.cancel()
        #expect(done.wait(seconds: Wait.ceiling) == true)
        #expect(bench.memory.allPaths.allSatisfy { !$0.hasSuffix(".tmp") && !$0.hasSuffix("sent.tar") })
    }

    /// A member larger than a window of the parallel compressor is written whole across windows.
    @Test
    internal func aMemberLargerThanAWindowIsWrittenWhole() throws {
        let url = box.url("large.zip")
        let output = try OutputFile(creating: url, mode: 0o600)
        let packer = ZipPacker(output, level: 0, password: nil, encryption: .aes256, limits: .standard)
        let pieces = 2 * max(2, ProcessInfo.processInfo.activeProcessorCount * 2) + 1
        for name in ["large.bin", "after.txt"] {
            var left = name == "large.bin" ? pieces : 1
            let record = ZipRecord.new(
                name: name,
                isDirectory: false,
                modified: Date(),
                permissions: 0o644,
                isSymbolicLink: false
            )
            try packer.add(record, expectedSize: UInt64(left * ZipPacker.pieceSize), stored: false) {
                guard left > 0 else {
                    return nil
                }
                left -= 1
                return Data(repeating: UInt8(left & 0xFF), count: ZipPacker.pieceSize)
            }
        }
        try packer.finish(comment: Data())
        try output.close(durably: false)
        let records = try ZipDirectory.read(try RandomAccessFile(url, shownAs: nil), maxEntries: .max, check: nil)
            .records
        #expect(records.map(\.name) == ["large.bin", "after.txt"])
        #expect(records.map(\.uncompressedSize) == [UInt64(pieces * ZipPacker.pieceSize), UInt64(ZipPacker.pieceSize)])
        let large = bench.inside(url, "large.bin")
        let reader = try bench.fileSystems.provider(for: large).read(large)
        defer { reader.close() }
        var total = 0
        while let block = try reader.read(upToCount: 1 << 20) {
            total += block.count
        }
        #expect(total == pieces * ZipPacker.pieceSize)
    }
}
