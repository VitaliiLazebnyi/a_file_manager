import Foundation
import TestSupport
import Testing

@testable import FileOperationsPlugin

// Regression tests of the reviewed defects in the file-operation plugins (F1 … F20).

/// The job engine: locked files, letter case, the target inside the source (F1, F4).
@Suite
internal struct FileOpsFixJobs {
    // MARK: F1

    /// A copy of a locked file leaves no temporary name in the target, whether or not it arrived.
    @Test
    internal func aCopyOfALockedFileLeavesNoTemporaryFileBehind() throws {
        let box = try Sandbox()
        let source = try box.file("A/locked.txt", "l")
        try box.folder("B")
        #expect(chflags(source.path, UInt32(UF_IMMUTABLE)) == 0)
        defer {
            chflags(source.path, 0)
            for name in namesOnDisk(box.url("B")) { chflags(box.url("B/" + name).path, 0) }
        }
        let replies = Replies()
        replies.run(
            .copy,
            [source],
            to: TargetSpec(directory: box.url("B")),
            fileSystems: makeFileSystems().0,
            configure: nil
        )
        // Whether the copy itself arrived depends on the file system; the temporary name must not stay.
        #expect(!namesOnDisk(box.url("B")).contains { $0.hasPrefix(".afm-") })
    }

    /// A file locked in the Finder is copied with its lock, without a question, and no temporary file stays.
    @Test
    internal func aFinderLockedFileIsCopiedWithItsLockByTheJobItself() throws {
        let box = try Sandbox()
        let source = try box.file("A/locked.txt", "locked content")
        try box.folder("B")
        #expect(chflags(source.path, UInt32(UF_IMMUTABLE)) == 0)
        let target = box.url("B/locked.txt")
        defer {
            chflags(source.path, 0)
            for name in namesOnDisk(box.url("B")) { chflags(box.url("B/" + name).path, 0) }
        }
        func flags(_ url: URL) -> UInt32 {
            var info = stat()
            return lstat(url.path, &info) == 0 ? info.st_flags : 0
        }
        // The job as the copy command makes it, with the options the dialog starts with.
        let replies = Replies()
        let result = replies.run(
            .copy,
            [source],
            to: TargetSpec(directory: box.url("B")),
            fileSystems: makeFileSystems().0,
            configure: nil
        )
        #expect(replies.errors.isEmpty && replies.conflicts.isEmpty)
        #expect(result.completed.count == 1 && box.read("B/locked.txt") == "locked content")
        // Locked like the source, which is untouched; and no temporary file is left.
        #expect(flags(target) & UInt32(UF_IMMUTABLE) != 0 && flags(source) & UInt32(UF_IMMUTABLE) != 0)
        #expect(namesOnDisk(box.url("B")) == ["locked.txt"] && namesOnDisk(box.url("A")) == ["locked.txt"])
        // The same file again, over the locked copy: whatever comes of it, nothing temporary stays behind.
        let again = Replies(.overwrite)
        again.run(
            .copy,
            [source],
            to: TargetSpec(directory: box.url("B")),
            fileSystems: makeFileSystems().0,
            configure: nil
        )
        #expect(
            !namesOnDisk(box.url("B")).contains { $0.hasPrefix(".afm-") }
                && box.read("B/locked.txt") == "locked content"
        )
    }

    // MARK: F4

    /// A target that lies inside the source by way of a link is refused.
    @Test
    internal func aTargetInsideTheSourceThroughALinkIsRefused() throws {
        let box = try Sandbox()
        try box.file("A/Foo/one.txt", "1")
        try FileManager.default.createSymbolicLink(at: box.url("A/link"), withDestinationURL: box.url("A/Foo"))
        let replies = Replies()
        let result = replies.run(
            .copy,
            [box.url("A/Foo")],
            to: TargetSpec(directory: box.url("A/link/sub")),
            fileSystems: makeFileSystems().0,
            configure: nil
        )
        #expect(replies.errors.count == 1 && replies.errors[0].contains("own subfolders"))
        #expect(result.completed.isEmpty && namesOnDisk(box.url("A/Foo")) == ["one.txt"])
    }

    /// Renaming a file or folder to another letter case is no conflict and no merge.
    @Test
    internal func aCaseOnlyRenameIsNotAConflict() throws {
        let box = try Sandbox()
        try box.file("A/readme.txt", "r")
        try box.file("A/Folder/in.txt", "i")
        let replies = Replies()
        let file = replies.run(
            .move,
            [box.url("A/readme.txt")],
            to: TargetSpec(directory: box.url("A"), exactName: "README.txt"),
            fileSystems: makeFileSystems().0,
            configure: nil
        )
        let folder = replies.run(
            .move,
            [box.url("A/Folder")],
            to: TargetSpec(directory: box.url("A"), exactName: "FOLDER"),
            fileSystems: makeFileSystems().0,
            configure: nil
        )
        #expect(replies.conflicts.isEmpty && replies.merges.isEmpty && replies.errors.isEmpty)
        #expect(file.completed.count == 1 && folder.completed.count == 1)
        #expect(namesOnDisk(box.url("A")) == ["FOLDER", "README.txt"])
        #expect(box.read("A/README.txt") == "r" && box.read("A/FOLDER/in.txt") == "i")
    }

    /// On a volume that folds case, a copy onto its own name in other letters is a copy onto itself.
    @Test
    internal func aCopyOntoItsOwnNameInOtherLetterCaseIsACopyOntoItself() throws {
        let box = try Sandbox()
        guard try isCaseInsensitive(box) else {
            return
        }
        try box.file("A/readme.txt", "r")
        let replies = Replies()
        replies.run(
            .copy,
            [box.url("A/readme.txt")],
            to: TargetSpec(directory: box.url("A"), exactName: "README.TXT"),
            fileSystems: makeFileSystems().0,
            configure: nil
        )
        #expect(replies.conflicts.isEmpty && replies.errors == ["You cannot copy a file to itself!"])
        #expect(box.read("A/readme.txt") == "r")
    }

    /// Two sources whose target names differ only in case meet as one conflict on a volume that folds case.
    @Test
    internal func twoSourcesWhoseTargetNamesDifferInCaseOnlyAreOneConflict() throws {
        let box = try Sandbox()
        guard try isCaseInsensitive(box) else {
            return
        }
        try box.file("A/x.txt", "a")
        try box.file("B/X.txt", "b")
        try box.folder("C")
        let replies = Replies(.skip)
        replies.run(
            .copy,
            [box.url("A/x.txt"), box.url("B/X.txt")],
            to: TargetSpec(directory: box.url("C")),
            fileSystems: makeFileSystems().0,
            configure: nil
        )
        #expect(replies.conflicts.count == 1 && replies.errors.isEmpty)
        #expect(namesOnDisk(box.url("C")).count == 1)
    }

    /// Whether the sandbox's volume takes names that differ in letter case for one.
    private func isCaseInsensitive(_ box: Sandbox) throws -> Bool {
        try box.file("probe-Case", "p")
        return box.exists("probe-case")
    }
}
