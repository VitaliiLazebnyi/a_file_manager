import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FileToolsPlugin

/// The surroundings of a file tool and split and combine, beyond the other suites: reads and
/// writes that fail or are cancelled, files in the way, replacements that cannot be made, and
/// rows of parts that cannot be made or named.
@Suite
internal struct CoverageFileToolsRun {
    /// The files: `/A` with two files.
    private let memory = MemoryFileSystem()
    /// The memory files behind a layer that fails what a test names.
    private let files: CoverageSmallFiles
    /// The layer, as the tools find it.
    private let fileSystems = FileSystemRegistry()

    /// The files and the registry.
    internal init() {
        memory.addFile("/A/one.txt", "one")
        memory.addFile("/A/two.txt", "two")
        files = CoverageSmallFiles(memory)
        fileSystems.register(files)
    }

    /// A run that answers every question about a file in the way with `answer`, counting them.
    private func run(
        _ answer: ExistingFileChoice = .overwrite,
        asked: Shared<Int> = Shared(0),
        cancellation: CancellationFlag = CancellationFlag()
    ) -> ToolRun {
        let answering: @Sendable (URL) -> ExistingFileChoice = { _ in
            asked.modify { $0 += 1 }
            return answer
        }
        return ToolRun(fileSystems: fileSystems, cancellation: cancellation, askExisting: answering)
    }

    /// The item of a memory path.
    private func item(_ path: String) throws -> FileItem {
        try #require(memory.item(at: memory.url(path)))
    }

    /// A cancelled tool says so.
    @Test
    internal func aCancelledToolSaysSo() {
        #expect(ToolError.cancelled.localizedDescription == "The operation was cancelled.")
    }

    /// A read or the opening of a writer that fails because of the cancel is the cancel.
    @Test
    internal func failuresBecauseOfTheCancelAreTheCancel() {
        let flag = CancellationFlag()
        files.fails = [.read, .create]
        files.onFailure = { _ in flag.cancel() }
        let tool = run(cancellation: flag)
        let received = Shared(0)
        #expect(throws: ToolError.cancelled) {
            try tool.read(memory.url("/A/one.txt")) { block in received.modify { $0 += block.count } }
        }
        #expect(received.value == 0)
        #expect(throws: ToolError.cancelled) { try tool.create(memory.url("/A/new.txt")) }
    }

    /// Overwrite all is asked once; files that cannot be written are dropped again.
    @Test
    internal func overwriteAllIsAskedOnceAndFailedWritesAreDropped() throws {
        let asked = Shared(0)
        let tool = run(.overwriteAll, asked: asked)
        try tool.write(Data("1".utf8), to: memory.url("/A/one.txt"))
        try tool.write(Data("2".utf8), to: memory.url("/A/two.txt"))
        #expect(asked.value == 1 && memory.contents("/A/one.txt") == "1" && memory.contents("/A/two.txt") == "2")
        files.fails = [.write]
        #expect(throws: CoverageSmallFiles.Failure.self) {
            try tool.write(Data("3".utf8), to: memory.url("/A/three.txt"))
        }
        #expect(!memory.exists("/A/three.txt"))
    }

    /// A file the user skips is not written.
    @Test
    internal func aSkippedFileIsNotWritten() throws {
        #expect(try run(.skip).write(Data("x".utf8), to: memory.url("/A/one.txt")) == nil)
        #expect(memory.contents("/A/one.txt") == "one")
    }

    /// When the new files cannot take the place of the old ones, all of them are taken back
    /// and the old files stay.
    @Test
    internal func replacementsThatCannotBeMadeAreTakenBack() throws {
        let tool = run()
        files.fail(.move, times: 1)
        #expect(throws: CoverageSmallFiles.Failure.self) {
            try tool.transaction {
                try tool.write(Data("1".utf8), to: memory.url("/A/one.txt"), deferred: true)
                try tool.write(Data("2".utf8), to: memory.url("/A/two.txt"), deferred: true)
            }
        }
        #expect(memory.contents("/A/one.txt") == "one" && memory.contents("/A/two.txt") == "two")
        #expect(memory.allPaths == ["/A", "/A/one.txt", "/A/two.txt"])
    }

    /// A free name for a file without an extension.
    @Test
    internal func freeNamesWithoutAnExtension() {
        memory.addFile("/A/name")
        memory.addFile("/A/name(2)")
        #expect(ToolRun.freeName(for: memory.url("/A/name"), provider: files) == memory.url("/A/name(3)"))
    }

    /// An output that fails to write, close or take the place of the old file is dropped; a
    /// failure because of the cancel is the cancel.
    @Test
    internal func outputsThatFail() throws {
        let flag = CancellationFlag()
        let tool = run(cancellation: flag)
        let writing = try #require(try tool.create(memory.url("/A/w.txt")))
        files.fails = [.write]
        files.onFailure = { _ in flag.cancel() }
        #expect(throws: ToolError.cancelled) { try writing.write(Data("x".utf8)) }
        writing.abandon()
        files.fails = [.close]
        files.onFailure = nil
        let closing = try #require(try run().create(memory.url("/A/c.txt")))
        #expect(throws: CoverageSmallFiles.Failure.self) { try closing.finish() }
        try closing.finish()
        #expect(!memory.exists("/A/c.txt"))
        let later = CancellationFlag()
        files.onFailure = { _ in later.cancel() }
        let cancelled = try #require(try run(cancellation: later).create(memory.url("/A/d.txt")))
        #expect(throws: ToolError.cancelled) { try cancelled.finish() }
        files.fails = []
        let replacing = try #require(try run().create(memory.url("/A/one.txt"), deferred: true))
        try replacing.write(Data("new".utf8))
        try replacing.finish()
        files.fails = [.move]
        #expect(throws: CoverageSmallFiles.Failure.self) { try replacing.commit() }
        replacing.undo()
        replacing.undo()
        #expect(memory.contents("/A/one.txt") == "one" && memory.allPaths.count == 3)
    }

    /// Split: a part file the user skips, or a checksum file skipped at the end, cancels the
    /// split; more than the most parts there may be is refused.
    @Test
    internal func splitsThatCannotBeMade() throws {
        memory.addFile("/A/one.001", "old")
        #expect(throws: ToolError.cancelled) {
            try Splitter.split(try item("/A/one.txt"), into: memory.url("/A"), partSize: 2, run: run(.skip))
        }
        memory.removeTree("/A/one.001")
        memory.addFile("/A/one.crc", "old")
        #expect(throws: ToolError.cancelled) {
            try Splitter.split(try item("/A/one.txt"), into: memory.url("/A"), partSize: 2, run: run(.skip))
        }
        // The file grows after it was listed: more parts than planned are not made.
        memory.addFile("/B/big.bin", "x")
        let listed = try item("/B/big.bin")
        memory.addFile("/B/big.bin", String(repeating: "x", count: Splitter.maximumParts + 1))
        memory.addDirectory("/C")
        #expect(throws: ToolError.failed("More than \(Splitter.maximumParts) parts.")) {
            try Splitter.split(listed, into: memory.url("/C"), partSize: 1, run: run())
        }
        #expect(!memory.allPaths.contains { $0.hasPrefix("/C/") })
    }

    /// The pieces of split and combine that read what a person may have written.
    @Test
    internal func sizesInfoAndCounters() {
        #expect(Splitter.size(from: "0.1") == nil && Splitter.size(from: "10kb") == 10_240)
        #expect(Splitter.size(from: "2b") == nil && Splitter.size(from: "kb") == nil)
        #expect(
            SplitInfo(text: "junk\nfilename=a.bin\nsize=3\ncrc32=FF\n") == SplitInfo(name: "a.bin", size: 3, crc: 0xFF)
        )
        #expect(PartSeries.next(after: "fileAB") == nil)
        #expect(PartSeries.next(after: "x." + String(repeating: "0", count: 19)) == nil)
    }

    /// Combine: nothing to combine, a name that is no file name, and a target the user skips.
    @Test
    internal func combinesThatCannotBeMade() throws {
        #expect(throws: ToolError.failed("No files selected!")) {
            try Combiner.combine([], info: nil, into: memory.url("/B"), run: run())
        }
        memory.addFile("/A/..001", "x")
        #expect(throws: ToolError.failed("The name of the combined file is not a file name.")) {
            try Combiner.combine([try item("/A/..001")], info: nil, into: memory.url("/B"), run: run())
        }
        memory.addFile("/A/data.001", "x")
        memory.addFile("/B/data", "old")
        #expect(throws: ToolError.cancelled) {
            try Combiner.combine([try item("/A/data.001")], info: nil, into: memory.url("/B"), run: run(.skip))
        }
        #expect(memory.contents("/B/data") == "old")
    }

    /// Hashers take an empty block as nothing.
    @Test
    internal func hashersTakeAnEmptyBlockAsNothing() {
        let crc = CRC32Hasher()
        crc.update(Data())
        #expect(crc.checksum == 0)
        let sha3 = SHA3Hasher(digestLength: 32)
        sha3.update(Data())
        #expect(sha3.finish().hex == "a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a")
    }

    /// Progress from many threads at once is passed on at most twenty times a second, and a
    /// later report never shows less than an earlier one.
    @Test
    internal func progressFromManyThreadsIsThrottled() {
        let reports = Shared<[Int64]>([])
        let tool = ToolRun(fileSystems: fileSystems) { progress in reports.modify { $0.append(progress.bytesDone) } }
        let start = Date()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<20_000 { tool.advance(1) }
        }
        let windows = Int(Date().timeIntervalSince(start) / 0.05) + 1
        tool.advance(0, force: true)
        let sent = reports.value
        #expect(sent.count <= windows + 1 && sent.last == 160_000)
        #expect(zip(sent, sent.dropFirst()).allSatisfy { $0 <= $1 })
    }
}
