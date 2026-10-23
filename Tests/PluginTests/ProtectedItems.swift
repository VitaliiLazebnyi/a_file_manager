import FileOperationsPlugin
import Foundation
import TestSupport
import Testing

/// Read-only, hidden and locked items, and merging into an existing folder.
@Suite
internal struct ProtectedItems {
    /// A read-only target brings a second question after Overwrite, unless the dialog's option takes it away.
    @Test
    internal func aReadOnlyTargetAsksASecondTime() throws {
        let box = try Sandbox()
        try box.file("A/one.txt", "new")
        try box.file("B/one.txt", "old")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: box.url("B/one.txt").path)
        let keep = Replies(.overwrite)
        keep.protection = .skip
        let skipped = keep.run(
            .copy,
            [box.url("A/one.txt")],
            to: TargetSpec(directory: box.url("B")),
            fileSystems: makeFileSystems().0,
            configure: nil
        )
        #expect(
            keep.protections == ["readOnly overwrite one.txt"] && box.read("B/one.txt") == "old"
                && skipped.completed.isEmpty
        )

        let replace = Replies(.overwrite)
        replace.run(
            .copy,
            [box.url("A/one.txt")],
            to: TargetSpec(directory: box.url("B")),
            fileSystems: makeFileSystems().0,
            configure: nil
        )
        #expect(replace.protections.count == 1 && box.read("B/one.txt") == "new")

        // "Overwrite/Delete read only/hidden" in the dialog takes the question away.
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: box.url("B/one.txt").path)
        let quiet = Replies(.overwrite)
        quiet.run(
            .copy,
            [box.url("A/one.txt")],
            to: TargetSpec(directory: box.url("B")),
            fileSystems: makeFileSystems().0
        ) { job in
            job.options.ignoresProtection = true
        }
        #expect(quiet.protections.isEmpty)
    }

    /// Deleting a read-only or (when asked for) a hidden file asks first, and All answers for the rest of the job.
    @Test
    internal func deletingReadOnlyAndHiddenFilesAsks() {
        let (fileSystems, memory) = makeFileSystems()
        memory.addFile("/a/ro.txt", "r", permissions: 0o444)
        memory.addFile("/a/.hidden", "h")
        memory.addFile("/a/plain.txt", "p")
        let sources = [memory.url("/a/ro.txt"), memory.url("/a/.hidden"), memory.url("/a/plain.txt")]
        let keep = Replies()
        keep.protection = .skip
        let kept = keep.run(.delete(toTrash: false), sources, to: nil, fileSystems: fileSystems) { job in
            job.options.asksAboutHidden = true
        }
        #expect(Set(keep.protections) == ["readOnly delete ro.txt", "hidden delete .hidden"])
        #expect(memory.allPaths == ["/a", "/a/.hidden", "/a/ro.txt"] && kept.completed.count == 1)

        // "All" answers the question for the rest of the job; hidden files are not asked about by default.
        memory.addFile("/a/ro2.txt", "r", permissions: 0o400)
        let all = Replies()
        all.protection = .all
        all.run(
            .delete(toTrash: false),
            sources + [memory.url("/a/ro2.txt")],
            to: nil,
            fileSystems: fileSystems,
            configure: nil
        )
        #expect(all.protections == ["readOnly delete ro.txt"] && memory.allPaths == ["/a"])
    }

    /// A locked file the system refuses to delete is asked about, kept on Skip and deleted on Proceed.
    @Test
    internal func aLockedFileIsAskedAboutWhenTheSystemRefuses() throws {
        let box = try Sandbox()
        let locked = try box.file("A/locked.txt", "l")
        #expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(locked.path, 0) }
        let keep = Replies()
        keep.protection = .skip
        let kept = keep.run(
            .delete(toTrash: false),
            [locked],
            to: nil,
            fileSystems: makeFileSystems().0,
            configure: nil
        )
        #expect(
            keep.protections == ["locked delete locked.txt"] && box.exists("A/locked.txt") && kept.completed.isEmpty
                && keep.errors.isEmpty
        )
        let delete = Replies()
        let deleted = delete.run(
            .delete(toTrash: false),
            [locked],
            to: nil,
            fileSystems: makeFileSystems().0,
            configure: nil
        )
        #expect(delete.protections.count == 1 && !box.exists("A/locked.txt") && deleted.completed.count == 1)
    }

    /// With the option on, merging into an existing folder is asked about first; without it folders merge silently.
    @Test
    internal func mergingIntoAnExistingFolderCanBeAskedAbout() {
        let (fileSystems, memory) = makeFileSystems()
        memory.addFile("/a/docs/one.txt", "1")
        memory.addFile("/b/docs/keep.txt", "k")
        let skip = Replies()
        skip.merge = .skip
        let target = TargetSpec(directory: memory.url("/b"))
        let skipped = skip.run(.copy, [memory.url("/a/docs")], to: target, fileSystems: fileSystems) { job in
            job.options.asksBeforeMerging = true
        }
        #expect(skip.merges == ["docs"] && !memory.exists("/b/docs/one.txt") && skipped.completed.isEmpty)
        let merge = Replies()
        merge.run(.copy, [memory.url("/a/docs")], to: target, fileSystems: fileSystems) { job in
            job.options.asksBeforeMerging = true
        }
        #expect(memory.exists("/b/docs/one.txt") && memory.exists("/b/docs/keep.txt"))
        // Without the option folders merge silently, as before.
        let silent = Replies(.overwrite)
        silent.run(.copy, [memory.url("/a/docs")], to: target, fileSystems: fileSystems, configure: nil)
        #expect(silent.merges.isEmpty && silent.conflicts == ["one.txt"])
    }
}
