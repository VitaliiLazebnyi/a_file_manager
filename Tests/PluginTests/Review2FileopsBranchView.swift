import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing
import VirtualFoldersPlugin

@testable import FileOperationsPlugin

/// Moves, copies and renames into a branch view, which shows a real folder with all its subfolders flat.
@Suite
internal struct Review2FileopsBranchView {
    /// A scratch folder of its own for each test.
    internal let box: Sandbox
    /// The local disk and the virtual file system.
    internal let fileSystems = FileSystemRegistry()
    /// The virtual file system that makes the branch views.
    internal let virtual: VirtualFileSystem

    /// A fresh scratch folder, with the local disk and branch views.
    internal init() throws {
        box = try Sandbox()
        fileSystems.register(LocalFileSystem())
        virtual = VirtualFileSystem(fileSystems: fileSystems)
        fileSystems.register(virtual)
    }

    private func run(
        _ kind: JobKind,
        _ sources: [URL],
        to target: TargetSpec,
        replies: Review2Replies = Review2Replies(),
        configure: ((FileJob) -> Void)? = nil
    ) -> JobResult {
        let job = FileJob(kind: kind, sources: sources, target: target, fileSystems: fileSystems)
        job.delegate = replies
        configure?(job)
        return job.run()
    }

    // F001, F018
    /// Moving a file into the branch view of its own folder is refused and the file is kept.
    @Test
    internal func movingAFileOntoItselfThroughABranchViewKeepsTheFile() throws {
        let file = try box.file("d/a.txt", "precious")
        let replies = Review2Replies()
        let result = run(.move, [file], to: TargetSpec(directory: virtual.branch(of: box.url("d"))), replies: replies)
        #expect(box.read("d/a.txt") == "precious")
        #expect(result.completed.isEmpty && replies.errors == ["You cannot copy a file to itself!"])
        #expect(namesOnDisk(box.url("d")) == ["a.txt"])
    }

    /// A target in a branch view is the real folder, and a list of files takes no names.
    @Test
    internal func aTargetInABranchViewIsTheRealFolder() throws {
        let job = FileJob(
            kind: .move,
            sources: [try box.file("d/a.txt")],
            target: TargetSpec(directory: virtual.branch(of: box.url("d"))),
            fileSystems: fileSystems
        )
        #expect(job.target?.directory.isFileURL == true && job.target?.directory.path == box.url("d").path)
        #expect(job.targetsSourceFolder)
        #expect(RealLocation.resolve(box.url("d"), in: fileSystems) == box.url("d"))
        // A list of files has no folder of its own, and no name can be written into it.
        let list = virtual.register(files: [box.url("d/a.txt")], title: "Found", origin: box.url("d"))
        #expect(RealLocation.resolve(list, in: fileSystems) == list)
        #expect(
            !RealLocation.takesNames(list, in: fileSystems) && RealLocation.takesNames(box.url("d"), in: fileSystems)
        )
    }

    /// Changing the letter case of a name in a branch view renames the same file.
    @Test
    internal func aRenameToAnotherLetterCaseInABranchViewIsARename() throws {
        let file = try box.file("d/a.txt", "precious")
        let before = try #require(Review2Stat.inode(file))
        let replies = Review2Replies()
        let result = run(
            .move,
            [file],
            to: TargetSpec(directory: virtual.branch(of: box.url("d")), exactName: "A.TXT"),
            replies: replies
        )
        #expect(replies.errors.isEmpty && replies.conflicts.isEmpty && result.completed.count == 1)
        #expect(namesOnDisk(box.url("d")) == ["A.TXT"] && box.read("d/A.TXT") == "precious")
        // The same file, renamed: not a copy that took its place.
        #expect(Review2Stat.inode(box.url("d/A.TXT")) == before)
    }

    /// A rename in a branch view keeps the file and its extended attributes, as a rename does.
    @Test
    internal func aPlainRenameInABranchViewIsARenameNotACopy() throws {
        let file = try box.file("d/a.txt", "precious")
        let before = try #require(Review2Stat.inode(file))
        #expect(setxattr(file.path, "user.afm.test", "v", 1, 0, 0) == 0)
        let result = run(
            .move,
            [file],
            to: TargetSpec(directory: virtual.branch(of: box.url("d")), exactName: "b.txt")
        )
        #expect(result.completed.count == 1 && namesOnDisk(box.url("d")) == ["b.txt"])
        #expect(Review2Stat.inode(box.url("d/b.txt")) == before)
        #expect(getxattr(box.url("d/b.txt").path, "user.afm.test", nil, 0, 0, 0) == 1)
    }

    /// A folder is not moved into itself or its own subfolder through a branch view.
    @Test
    internal func aFolderIsNotMovedIntoItselfThroughABranchView() throws {
        try box.file("d/sub/in.txt", "inside")
        let replies = Review2Replies()
        // Into itself under its own name, and into its own subfolder.
        _ = run(
            .move,
            [box.url("d/sub")],
            to: TargetSpec(directory: virtual.branch(of: box.url("d"))),
            replies: replies
        )
        _ = run(
            .move,
            [box.url("d/sub")],
            to: TargetSpec(directory: virtual.branch(of: box.url("d/sub"))),
            replies: replies
        )
        #expect(box.read("d/sub/in.txt") == "inside" && replies.errors.count == 2)
    }

    /// Copying a file onto itself through a branch view is refused.
    @Test
    internal func copyingOntoItselfThroughABranchViewIsRefused() throws {
        let file = try box.file("d/a.txt", "precious")
        let replies = Review2Replies()
        _ = run(.copy, [file], to: TargetSpec(directory: virtual.branch(of: box.url("d"))), replies: replies)
        #expect(box.read("d/a.txt") == "precious" && replies.errors == ["You cannot copy a file to itself!"])
        #expect(namesOnDisk(box.url("d")) == ["a.txt"])
    }

    /// A target that is a hard link of the source is not overwritten with itself.
    @Test
    internal func aHardLinkOfTheSourceIsNotOverwrittenWithItself() throws {
        let file = try box.file("d/a.txt", "precious")
        try box.folder("t")
        try FileManager.default.linkItem(at: file, to: box.url("t/a.txt"))
        let replies = Review2Replies()
        _ = run(.move, [file], to: TargetSpec(directory: box.url("t")), replies: replies) { job in
            job.options.overwrite = .overwriteAll
        }
        #expect(box.read("d/a.txt") == "precious" && box.read("t/a.txt") == "precious" && replies.errors.count == 1)
    }

    // F006: a rename of several items to one name.
    /// Several items renamed to one name each stay in their folder, and two of one folder both survive.
    @Test
    internal func severalItemsRenamedToOneNameAreAllKept() throws {
        let sources = [
            try box.file("d/a.doc", "doc"), try box.file("d/a.pdf", "pdf"), try box.file("d/sub/a.rtf", "rtf")
        ]
        let replies = Review2Replies()
        let result = run(.move, sources, to: TargetSpec(directory: box.url("d")), replies: replies) { job in
            job.newNames = Dictionary(uniqueKeysWithValues: sources.map { ($0.locationKey, "a.txt") })
            job.options.overwrite = .overwriteAll
        }
        #expect(result.completed.count == 3 && replies.conflicts.isEmpty)
        // Each stays in its own folder; the two of one folder both survive.
        #expect(namesOnDisk(box.url("d")) == ["a (2).txt", "a.txt", "sub"] && box.read("d/sub/a.txt") == "rtf")
        #expect(Set([box.read("d/a.txt"), box.read("d/a (2).txt")]) == ["doc", "pdf"])
    }
}
