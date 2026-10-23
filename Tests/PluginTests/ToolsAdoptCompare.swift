import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import CompareContentPlugin

/// Compare by content with names and texts that differ only in their Unicode form, and its cancel.
@Suite
internal struct ToolsAdoptCompare {
    /// Lines that differ only in their Unicode form are equal, by hash and by key.
    @Test
    internal func linesThatDifferOnlyInNormalisationAreEqual() {
        let options = DiffOptions()
        let nfc = TextLine("caf\u{e9} au lait")
        let nfd = TextLine("cafe\u{301} au lait")
        #expect(options.hash(nfc) == options.hash(nfd) && options.isSameKey(nfc, nfd))
        var exact = DiffOptions()
        exact.ignoreCase = false
        exact.ignoreRepeatedSpaces = false
        exact.ignoreLineEndings = false
        #expect(exact.hash(nfc) == exact.hash(nfd))
        let diff = TextDiff.compute(
            left: [nfc, TextLine("same"), TextLine("\u{c5}ngstr\u{f6}m")],
            right: [nfd, TextLine("same"), TextLine("A\u{30a}ngstro\u{308}m")],
            options: options
        )
        #expect(diff.isIdentical)
        // ASCII is hashed as it is, and a real difference still shows.
        #expect(options.hash(TextLine("Hello  world")) == options.hash(TextLine("hello world")))
        #expect(options.hash(TextLine("caf\u{e9}")) != options.hash(TextLine("cafe")))
        #expect(!TextDiff.compute(left: [nfc], right: [TextLine("cafe au lait")], options: options).isIdentical)
    }

    /// Two files whose texts differ only in their Unicode form show no difference, and are not the same bytes.
    @Test
    internal func comparisonIgnoresNormalisationInFiles() {
        let memory = MemoryFileSystem()
        let registry = FileSystemRegistry()
        registry.register(memory)
        memory.addFile("/a.txt", "caf\u{e9}\nsame\n")
        memory.addFile("/b.txt", "cafe\u{301}\nsame\n")
        let result = CompareLoader.load(left: memory.url("/a.txt"), right: memory.url("/b.txt"), fileSystems: registry)
        if case .text(_, _, let diff, _) = result.content {
            #expect(diff.isIdentical)
        } else {
            Issue.record("not text")
        }
        #expect(!result.isIdentical)
    }

    /// Of two names that read alike, the marked one is the file compared.
    @MainActor
    @Test
    internal func theChosenFilesAreTheMarkedTwins() {
        let memory = MemoryFileSystem()
        memory.addFile("/A/" + ToolsAdopt.composed, "x")
        memory.addFile("/A/" + ToolsAdopt.decomposed, "y")
        memory.addFile("/B/other.txt", "z")
        let bench = TestBench(
            plugins: [],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/B"),
            settings: MemorySettings()
        )
        bench.left.model.setSelected(true, names: [ToolsAdopt.decomposed])
        bench.right.model.setSelected(true, names: ["other.txt"])
        let (left, right) = CompareOperands.choose(source: bench.left.model, target: bench.right.model)
        #expect(
            left.map { ToolsAdopt.isExactly($0.lastPathComponent, ToolsAdopt.decomposed) } == true
                && right?.lastPathComponent == "other.txt"
        )
    }

    /// The cancel ends a load that waits on a read.
    @Test
    internal func cancellingEndsABlockedLoad() {
        let memory = MemoryFileSystem()
        memory.addFile("/a.txt", "one\n")
        memory.addFile("/b.txt", "two\n")
        let probe = ToolsAdopt.ProbingFileSystem(memory)
        let registry = FileSystemRegistry()
        registry.register(probe)
        memory.stallsReads = true
        defer { memory.releaseStalls() }
        let flag = CancellationFlag()
        let result = ToolsAdopt.Outcome<ComparedFiles>()
        let done = ToolsAdopt.background {
            result.value = CompareLoader.load(
                left: memory.url("/a.txt"),
                right: memory.url("/b.txt"),
                fileSystems: registry,
                cancellation: flag
            )
        }
        #expect(probe.reading.wait(timeout: .now() + Wait.ceiling) == .success)
        ToolsAdopt.cancelFromThread(flag)
        #expect(done.wait(timeout: .now() + Wait.ceiling) == .success)
        #expect(result.value?.wasCancelled == true && result.value?.message == nil && memory.interruptions >= 1)
    }

    /// The cancel ends a check for identical files that waits on a read.
    @Test
    internal func cancellingEndsABlockedIdentityCheck() {
        let memory = MemoryFileSystem()
        memory.isLocal = false
        memory.addFile("/a", String(repeating: "0123456789", count: 1_000))
        memory.addFile("/b", String(repeating: "0123456789", count: 1_000))
        let probe = ToolsAdopt.ProbingFileSystem(memory)
        let registry = FileSystemRegistry()
        registry.register(probe)
        memory.stallsReads = true
        defer { memory.releaseStalls() }
        let flag = CancellationFlag()
        let done = ToolsAdopt.background {
            _ = try? CompareLoader.identical(
                memory.url("/a"),
                memory.url("/b"),
                size: 10_000,
                fileSystems: registry,
                cancellation: flag
            )
        }
        #expect(probe.reading.wait(timeout: .now() + Wait.ceiling) == .success)
        ToolsAdopt.cancelFromThread(flag)
        #expect(done.wait(timeout: .now() + Wait.ceiling) == .success)
    }
}
