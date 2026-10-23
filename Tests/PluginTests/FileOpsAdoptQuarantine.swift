import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FileOperationsPlugin

/// Origin marks: what comes from a marked source is marked in the target.
@Suite
internal struct FileOpsAdoptQuarantine {
    /// The origin mark of a download.
    private let mark = Data("0083;5f5e1000;Browser;".utf8)

    /// Three files in a tree with a subfolder, under `/src/tree`.
    private func tree(in base: MemoryFileSystem) {
        base.addFile("/src/tree/a.txt", "a")
        base.addFile("/src/tree/b.txt", "b")
        base.addFile("/src/tree/sub/c.txt", "c")
    }

    /// Files and folders from a source with an origin mark are marked before they get their names.
    @Test
    internal func filesAndFoldersFromAMarkedSourceAreMarkedBeforeTheyGetTheirNames() {
        let source = MemoryFileSystem(scheme: "mem")
        source.quarantineValue = mark
        tree(in: source)
        let probe = ProbeFileSystem(source)
        let target = MemoryFileSystem(scheme: "arc")
        target.addDirectory("/out")
        let result = Answers()
            .run(
                .copy,
                [source.url("/src/tree")],
                to: TargetSpec(directory: target.url("/out")),
                fileSystems: FileSystemRegistry.localDisk(and: probe, target)
            )
        #expect(result.completed.count == 1)
        let marks = target.quarantineMarks
        // Three files under their temporary names, two folders under their own.
        #expect(marks.count == 5 && marks.values.allSatisfy { $0 == mark })
        #expect(marks.keys.filter { $0.contains(".afm-") }.count == 3)
        #expect(marks["/out/tree"] == mark && marks["/out/tree/sub"] == mark)
        // Asked once per source folder, not once per file.
        #expect(probe.count(of: "quarantine") == 2)
        #expect(target.contents("/out/tree/sub/c.txt") == "c")
    }

    /// Nothing is marked when the source has no mark or the copy stays within one file system.
    @Test
    internal func nothingIsMarkedWhenTheSourceHasNoMarkOrTheCopyStaysInOneFileSystem() {
        let source = MemoryFileSystem(scheme: "mem")
        tree(in: source)
        let target = MemoryFileSystem(scheme: "arc")
        target.addDirectory("/out")
        Answers()
            .run(
                .copy,
                [source.url("/src/tree")],
                to: TargetSpec(directory: target.url("/out")),
                fileSystems: FileSystemRegistry.localDisk(and: source, target)
            )
        #expect(target.quarantineMarks.isEmpty)

        let marked = MemoryFileSystem(scheme: "mem")
        marked.quarantineValue = mark
        tree(in: marked)
        marked.addDirectory("/out")
        Answers()
            .run(
                .copy,
                [marked.url("/src/tree")],
                to: TargetSpec(directory: marked.url("/out")),
                fileSystems: FileSystemRegistry.localDisk(and: marked)
            )
        #expect(marked.quarantineMarks.isEmpty)
    }

    /// A resumed file gets the origin mark too, continued in place or written anew.
    @Test
    internal func aResumedFileIsMarkedToo() {
        for continues in [true, false] {
            let source = MemoryFileSystem(scheme: "mem")
            source.quarantineValue = mark
            source.addFile("/s/file.txt", "hello world")
            let target = MemoryFileSystem(scheme: "arc")
            target.capabilities = continues ? [.write, .append] : [.write]
            target.addFile("/t/file.txt", "hello")
            let replies = Replies(.resume)
            replies.run(
                .copy,
                [source.url("/s/file.txt")],
                to: TargetSpec(directory: target.url("/t")),
                fileSystems: FileSystemRegistry.localDisk(and: source, target),
                configure: nil
            )
            #expect(target.contents("/t/file.txt") == "hello world")
            // Continued in place the file has its name already; written anew it is marked under the temporary name.
            let marks = target.quarantineMarks
            #expect(marks.count == 1 && marks.values.first == mark)
            #expect(marks.keys.first?.contains(".afm-") == !continues)
            if continues { #expect(marks["/t/file.txt"] == mark) }
        }
    }
}
