import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FileOperationsPlugin

/// Resume: continuing a partial file, or writing it anew where that cannot be done.
@Suite
internal struct FileOpsAdoptResume {
    /// A file system with the capabilities given, a source file and a partial target, and a probe on it.
    private func setUp(partial: String, source: String, capabilities: FileSystemCapabilities) -> (
        MemoryFileSystem, ProbeFileSystem
    ) {
        let base = MemoryFileSystem()
        base.capabilities = capabilities
        base.addFile("/s/file.txt", source)
        base.addFile("/t/file.txt", partial)
        return (base, ProbeFileSystem(base))
    }

    /// Copies the source onto the partial file with Resume as the answer; `verify` checks the copy.
    private func resume(_ base: MemoryFileSystem, _ probe: ProbeFileSystem, verify: Bool = false) -> Replies {
        let replies = Replies(.resume)
        replies.run(
            .copy,
            [base.url("/s/file.txt")],
            to: TargetSpec(directory: base.url("/t")),
            fileSystems: FileSystemRegistry.localDisk(and: probe)
        ) { job in
            job.options.verifies = verify
        }
        return replies
    }

    /// Resume continues the partial file in place where the file system can append.
    @Test
    internal func aResumeContinuesThePartialFileWhereTheFileSystemCanAppend() {
        let (base, probe) = setUp(
            partial: "hello wo",
            source: "hello world, resumed",
            capabilities: [.write, .append]
        )
        let replies = resume(base, probe)
        #expect(replies.errors.isEmpty)
        #expect(base.contents("/t/file.txt") == "hello world, resumed")
        #expect(probe.count(of: "append") == 1)
        #expect(probe.count(of: "write") == 0)
        #expect(!base.allPaths.contains { $0.contains(".afm-") })
    }

    /// Without append the resumed file is written anew and put in place of the partial one.
    @Test
    internal func withoutAppendTheFileIsWrittenAnewAndSwappedIn() {
        let (base, probe) = setUp(partial: "hello wo", source: "hello world, resumed", capabilities: [.write])
        let replies = resume(base, probe)
        #expect(replies.errors.isEmpty)
        #expect(base.contents("/t/file.txt") == "hello world, resumed")
        #expect(probe.count(of: "append") == 0)
        #expect(probe.count(of: "write") == 1)
    }

    /// A file system that claims append but refuses it gets the file written anew.
    @Test
    internal func aFileSystemThatClaimsAppendButRefusesItFallsBackToWritingAnew() {
        let (base, probe) = setUp(partial: "hello wo", source: "hello world, resumed", capabilities: [.write])
        probe.claims = .append
        let replies = resume(base, probe)
        #expect(replies.errors.isEmpty)
        #expect(base.contents("/t/file.txt") == "hello world, resumed")
        #expect(probe.count(of: "append") == 1 && probe.count(of: "write") == 1)
        #expect(!base.allPaths.contains { $0.contains(".afm-") })
    }

    /// A partial file that is not the start of the source is not continued.
    @Test
    internal func aPartialFileThatIsNotTheStartOfTheSourceIsNotContinued() {
        let (base, probe) = setUp(
            partial: "hellX wo",
            source: "hello world, resumed",
            capabilities: [.write, .append]
        )
        let replies = resume(base, probe)
        #expect(replies.errors.count == 1 && replies.errors[0].contains("cannot be resumed"))
        #expect(base.contents("/t/file.txt") == "hellX wo")
        #expect(probe.count(of: "append") == 0)
    }

    /// With verify, all of the partial file is compared with the source, not just its last block.
    @Test
    internal func verifyComparesAllOfThePartialFileNotJustItsLastBlock() {
        // A difference at the very start of a partial file of 1.5 MB is beyond the last block.
        let partial = "X" + String(repeating: "a", count: 1_500_000)
        let source = String(repeating: "a", count: 1_501_000) + "tail"
        let (base, probe) = setUp(partial: partial, source: source, capabilities: [.write, .append])
        let replies = resume(base, probe, verify: true)
        #expect(replies.errors.count == 1 && replies.errors[0].contains("cannot be resumed"))
        #expect(base.contents("/t/file.txt") == partial)

        let (good, goodProbe) = setUp(
            partial: String(repeating: "a", count: 1_500_000),
            source: source,
            capabilities: [.write, .append]
        )
        let intact = resume(good, goodProbe, verify: true)
        #expect(intact.errors.isEmpty && good.contents("/t/file.txt") == source)
        #expect(goodProbe.count(of: "append") == 1)
    }

    /// Resume on the local disk continues the same file rather than a new one.
    @Test
    internal func aResumeOnTheLocalDiskContinuesTheFileItself() throws {
        let box = try Sandbox()
        try box.file("S/f.txt", "0123456789abcdef")
        let partial = try box.file("T/f.txt", "01234567")
        let before = try FileManager.default.attributesOfItem(atPath: partial.path)[.systemFileNumber] as? Int
        let replies = Replies(.resume)
        replies.run(
            .copy,
            [box.url("S/f.txt")],
            to: TargetSpec(directory: box.url("T")),
            fileSystems: makeFileSystems().0,
            configure: nil
        )
        #expect(replies.errors.isEmpty)
        #expect(box.read("T/f.txt") == "0123456789abcdef")
        #expect(try FileManager.default.attributesOfItem(atPath: partial.path)[.systemFileNumber] as? Int == before)
        #expect(!namesOnDisk(box.url("T")).contains { $0.hasPrefix(".afm-") })
    }
}
