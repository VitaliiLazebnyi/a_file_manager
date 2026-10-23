import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FileOperationsPlugin

/// Hostile names, the Trash, and sources that cannot be removed (F5, F6, F7).
extension FileOpsFixJobs {
    // MARK: F5

    /// Listed names that lead out of their folder, or are no names at all, are reported and not copied.
    @Test
    internal func namesThatLeadOutOfTheirFolderAreNotTransferred() throws {
        let box = try Sandbox()
        try box.folder("Target")
        let fileSystems = FileSystemRegistry()
        let odd = OddFileSystem()
        fileSystems.register(LocalFileSystem())
        fileSystems.register(odd)
        odd.base.addFile("/d/ok.txt", "fine")
        odd.addHostile(names: ["../escape.txt", "a/b.txt", "..", ".", "", "nul\0.txt"], in: "/d")
        let replies = Replies()
        let result = replies.run(
            .copy,
            [odd.base.url("/d")],
            to: TargetSpec(directory: box.url("Target")),
            fileSystems: fileSystems,
            configure: nil
        )
        #expect(namesOnDisk(box.url("Target/d")) == ["ok.txt"])
        #expect(namesOnDisk(box.url("Target")) == ["d"] && namesOnDisk(box.root) == ["Target"])
        #expect(replies.errors.count == 6 && replies.errors.allSatisfy { $0.contains("not a valid file name") })
        #expect(result.failureCount == 6)
        // Nothing of it counts as processed, so a move would keep the folder.
        #expect(result.completed.isEmpty)
    }

    /// A move keeps a folder that held a refused name.
    @Test
    internal func aMoveKeepsAFolderWithARefusedName() throws {
        let box = try Sandbox()
        try box.folder("Target")
        let fileSystems = FileSystemRegistry()
        let odd = OddFileSystem()
        fileSystems.register(LocalFileSystem())
        fileSystems.register(odd)
        odd.base.addFile("/d/ok.txt", "fine")
        odd.addHostile(names: [".."], in: "/d")
        let replies = Replies()
        let result = replies.run(
            .move,
            [odd.base.url("/d")],
            to: TargetSpec(directory: box.url("Target")),
            fileSystems: fileSystems,
            configure: nil
        )
        #expect(result.completed.isEmpty && !odd.removed.contains(odd.base.url("/d")))
    }

    /// A delete never follows a hostile name out of the folder.
    @Test
    internal func deletingNeverFollowsAHostileName() {
        let fileSystems = FileSystemRegistry()
        let odd = OddFileSystem()
        fileSystems.register(odd)
        odd.base.addFile("/d/ok.txt", "fine")
        odd.addHostile(names: ["..", "x/y"], in: "/d")
        let replies = Replies()
        let result = replies.run(
            .delete(toTrash: false),
            [odd.base.url("/d")],
            to: nil,
            fileSystems: fileSystems,
            configure: nil
        )
        #expect(odd.removed.map(\.lastPathComponent) == ["ok.txt"])
        #expect(replies.errors.count == 2 && result.completed.isEmpty)
    }

    // MARK: F6

    /// Only a place without a Trash offers to delete for good; a refusal of the item is an error.
    @Test
    internal func onlyAPlaceWithoutATrashOffersPermanentDeletion() {
        let fileSystems = FileSystemRegistry()
        let odd = OddFileSystem()
        fileSystems.register(odd)
        odd.base.addFile("/a/one.txt", "1")
        odd.base.addFile("/a/two.txt", "2")
        let source = [odd.base.url("/a/one.txt"), odd.base.url("/a/two.txt")]

        // A refusal that is about this item is an error to decide on; nothing is deleted for good.
        odd.trashError = CocoaError(.fileWriteNoPermission)
        let denied = Replies()
        let first = denied.run(.delete(toTrash: true), source, to: nil, fileSystems: fileSystems, configure: nil)
        #expect(denied.protections.isEmpty && denied.errors.count == 2 && first.completed.isEmpty)
        #expect(odd.base.exists("/a/one.txt") && odd.base.exists("/a/two.txt"))

        // No Trash here: the question is whether to delete for good, and "All" holds for the rest.
        odd.trashError = CocoaError(.featureUnsupported)
        let noTrash = Replies()
        noTrash.protection = .all
        let second = noTrash.run(.delete(toTrash: true), source, to: nil, fileSystems: fileSystems, configure: nil)
        #expect(
            noTrash.protections == ["noTrash delete one.txt"] && second.completed.count == 2
                && !odd.base.exists("/a/one.txt")
        )
    }

    /// Retry after a failed move to the Trash asks the Trash again.
    @Test
    internal func aFailedTrashCanBeRetried() {
        let fileSystems = FileSystemRegistry()
        let odd = OddFileSystem()
        fileSystems.register(odd)
        odd.base.addFile("/a/one.txt", "1")
        odd.trashError = CocoaError(.fileWriteNoPermission)
        let job = FileJob(
            kind: .delete(toTrash: true),
            sources: [odd.base.url("/a/one.txt")],
            fileSystems: fileSystems
        )
        let delegate = RetryOnce()
        job.delegate = delegate
        _ = job.run()
        // Retry asks the Trash again; it is not the old error replayed.
        #expect(odd.trashedItems.count == 2 && delegate.errors.count == 2)
    }

    // MARK: F7

    /// Retry after the source of a move could not be removed removes it without copying again.
    @Test
    internal func removingTheSourceOfAMoveIsRetriedWithoutCopyingAgain() throws {
        let box = try Sandbox()
        try box.folder("B")
        let fileSystems = FileSystemRegistry()
        let odd = OddFileSystem()
        fileSystems.register(LocalFileSystem())
        fileSystems.register(odd)
        odd.base.addFile("/a/one.txt", "payload")
        odd.failNextRemovals(1)
        let job = FileJob(
            kind: .move,
            sources: [odd.base.url("/a/one.txt")],
            target: TargetSpec(directory: box.url("B")),
            fileSystems: fileSystems
        )
        let delegate = RetryOnce()
        job.delegate = delegate
        let result = job.run()
        #expect(delegate.errors.count == 1 && !delegate.errors[0].contains("already exists"))
        #expect(box.read("B/one.txt") == "payload" && !odd.base.exists("/a/one.txt") && result.completed.count == 1)
        #expect(namesOnDisk(box.url("B")) == ["one.txt"])
    }

    /// A source that cannot be removed stays and is not reported as moved.
    @Test
    internal func aSourceThatCannotBeRemovedStaysAndIsNotReportedAsMoved() throws {
        let box = try Sandbox()
        try box.folder("B")
        let fileSystems = FileSystemRegistry()
        let odd = OddFileSystem()
        fileSystems.register(LocalFileSystem())
        fileSystems.register(odd)
        odd.base.addFile("/a/one.txt", "payload")
        odd.failNextRemovals(5)
        let replies = Replies()
        let result = replies.run(
            .move,
            [odd.base.url("/a/one.txt")],
            to: TargetSpec(directory: box.url("B")),
            fileSystems: fileSystems,
            configure: nil
        )
        #expect(box.read("B/one.txt") == "payload" && odd.base.exists("/a/one.txt") && result.completed.isEmpty)
    }
}
