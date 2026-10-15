import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Test archive: a password the user declines, Cancel before and during the reading, and an
/// archive that changes under a pass.
@Suite
internal struct CoverageArchivesFormatsTester {
    private let bench: ArchiveBench
    private var box: Sandbox { bench.box }

    /// A new bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    private func archive(_ format: ArchiveFormat = .zip, password: String? = nil) throws -> URL {
        try box.file("tree/a.txt", "a")
        try box.file("tree/b.txt", "b")
        let archive = box.url("tree." + format.defaultExtension)
        try bench.pack([box.url("tree")], to: archive) { options in
            options.format = format
            options.password = password
        }
        return archive
    }

    /// An encrypted archive whose password the user declines gives that as its one problem.
    @Test
    internal func aDeclinedPasswordIsTheProblem() throws {
        let archive = try archive(password: "secret")
        bench.passwords.set([nil])
        let problems = ArchiveTester.test(try bench.store.archive(at: archive), cancellation: CancellationFlag())
        #expect(problems == [ArchiveError.passwordNeeded("tree.zip").localizedDescription])
    }

    /// A test cancelled before it starts reads nothing and finds nothing, in either kind of archive.
    @Test(arguments: [ArchiveFormat.zip, .compressedTar(.gzip)])
    internal func aCancelledTestFindsNothing(format: ArchiveFormat) throws {
        bench.environment.hasRoom = { _, _ in false }
        let archive = try archive(format)
        let flag = CancellationFlag()
        flag.cancel()
        let counter = SharedCounter()
        #expect(ArchiveTester.test(try bench.store.archive(at: archive), cancellation: flag, counter: counter).isEmpty)
        #expect(counter.value == 0)
    }

    /// A test cancelled in the middle of a member stops reading it and reports nothing.
    @Test
    internal func aTestCancelledInTheMiddleOfAMemberStops() throws {
        // One member of 64 GB that is all hole: read to its end it would take long.
        let url = box.url("huge.zip")
        let size: UInt64 = 64 << 30
        var record = ZipRecord.new(name: "huge.bin", isDirectory: false, modified: Date(), permissions: 0o644)
        record.uncompressedSize = size
        record.compressedSize = size
        let head = try OutputFile(creating: url)
        _ = try ZipWriter(head).begin(record, expectedSize: size)
        let dataStart = head.position
        try head.close()
        let tail = try OutputFile(extending: url, from: dataStart + size)
        let writer = ZipWriter(tail)
        writer.adopt(record, at: 0)
        try writer.finish()
        try tail.close()

        let open = try bench.store.archive(at: url)
        let flag = CancellationFlag()
        let counter = SharedCounter()
        let done = Signal<[String]>()
        OtherThread.start { done.set(ArchiveTester.test(open, cancellation: flag, counter: counter)) }
        #expect(Wait.until { counter.value > 0 })
        flag.cancel()
        #expect(done.wait() == [])
        #expect(counter.value < Int64(size))
    }

    /// An archive read in one pass that was changed since it was listed is reported.
    @Test
    internal func anArchiveChangedUnderAPassIsReported() throws {
        bench.environment.hasRoom = { _, _ in false }
        let archive = try archive(.compressedTar(.gzip))
        let open = try bench.store.archive(at: archive)
        #expect(!open.allowsParallelReads)
        // Another archive takes its contents, in the same file.
        try box.file("other/c.txt", "c")
        let other = box.url("other.tar.gz")
        try bench.pack([box.url("other")], to: other) { $0.format = .compressedTar(.gzip) }
        let handle = try FileHandle(forWritingTo: archive)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: try Data(contentsOf: other))
        try handle.close()
        let problems = ArchiveTester.test(open, cancellation: CancellationFlag())
        #expect(problems.count == 1 && !problems[0].hasPrefix("tree/"))
    }

    /// A member damaged in an archive read in one pass is reported by its path.
    @Test
    internal func aDamagedMemberInAPassIsReported() throws {
        bench.environment.hasRoom = { _, _ in false }
        var text = ""
        for line in 0..<200_000 {
            text += "line \(line)\n"
        }
        try box.file("tree/a.txt", text)
        let archive = box.url("tree.tar.gz")
        try bench.pack([box.url("tree")], to: archive) { $0.format = .compressedTar(.gzip) }
        let open = try bench.store.archive(at: archive)
        // The compressed data is overwritten in place from a third on, inside the member.
        var data = try Data(contentsOf: archive)
        let start = data.count / 3
        data.replaceSubrange(start..<(data.count - 20), with: Data(repeating: 0xFF, count: data.count - 20 - start))
        let handle = try FileHandle(forWritingTo: archive)
        try handle.write(contentsOf: data)
        try handle.close()
        let problems = ArchiveTester.test(open, cancellation: CancellationFlag())
        #expect(problems.first?.hasPrefix("tree/a.txt: ") == true, "\(problems) \(open.allowsParallelReads)")
    }

    /// Work in the background lets the waiting thread report while it runs.
    @Test
    internal func backgroundWorkLetsTheWaitingThreadReport() {
        let ticked = Signal<Bool>()
        var ticks = 0
        let value = Background.run(
            { ticked.wait() == true ? 42 : 0 },
            tick: {
                ticks += 1
                ticked.set(true)
            }
        )
        #expect(value == 42 && ticks >= 2)
    }
}
