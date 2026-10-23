import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FileOperationsPlugin

/// What a job does to targets that are links, locked, older or newer by fractions of a second, or loops.
@Suite
internal struct Review2FileopsJobTargets {
    /// A scratch folder of its own for each test.
    internal let box: Sandbox

    /// A fresh scratch folder.
    internal init() throws {
        box = try Sandbox()
    }

    // MARK: F022, F033

    /// Resume and Append refuse a target that is a link, and the file it points to stays as it was.
    @Test
    internal func resumeAndAppendNeverWriteThroughALinkAtTheTarget() throws {
        let (fileSystems, memory) = makeFileSystems()
        let victim = try box.file("elsewhere/victim.txt", "the victim's own, longer contents: fifty-three bytes.")
        try box.file("s/f.txt", String(repeating: "source-bytes ", count: 20))
        memory.addFile("/s/f.txt", String(repeating: "source-bytes ", count: 20))
        try box.folder("t")
        try FileManager.default.createSymbolicLink(at: box.url("t/f.txt"), withDestinationURL: victim)
        for (choice, source) in [
            (ConflictChoice.resume, box.url("s/f.txt")), (.append, box.url("s/f.txt")),
            (.resume, memory.url("/s/f.txt")),
            (.append, memory.url("/s/f.txt"))
        ] {
            let replies = Review2Replies()
            replies.conflict = choice
            let job = FileJob(
                kind: .copy,
                sources: [source],
                target: TargetSpec(directory: box.url("t")),
                fileSystems: fileSystems
            )
            job.delegate = replies
            let result = job.run()
            #expect(
                box.read("elsewhere/victim.txt") == "the victim's own, longer contents: fifty-three bytes.",
                "\(choice)"
            )
            #expect(FileIdentity.isSymlink(box.url("t/f.txt")) && result.completed.isEmpty && replies.errors.count == 1)
        }
    }

    /// Where a file cannot be continued, Resume writes it anew only when the target is the start of the source.
    @Test
    internal func resumeByWritingAnewChecksThatTheTargetIsTheStartOfTheSource() throws {
        // A file system that cannot continue a file: the longer file is written next to the old one.
        let fileSystems = FileSystemRegistry()
        let flaky = FlakyFileSystem()
        fileSystems.register(LocalFileSystem())
        fileSystems.register(flaky)
        try box.file("s/f.txt", "0123456789")
        flaky.base.addFile("/t/f.txt", "0123")
        flaky.base.addFile("/u/f.txt", "9999")
        let good = Review2Replies()
        good.conflict = .resume
        var job = FileJob(
            kind: .copy,
            sources: [box.url("s/f.txt")],
            target: TargetSpec(directory: flaky.base.url("/t")),
            fileSystems: fileSystems
        )
        job.delegate = good
        _ = job.run()
        #expect(flaky.base.contents("/t/f.txt") == "0123456789" && good.errors.isEmpty)
        let bad = Review2Replies()
        bad.conflict = .resume
        job = FileJob(
            kind: .copy,
            sources: [box.url("s/f.txt")],
            target: TargetSpec(directory: flaky.base.url("/u")),
            fileSystems: fileSystems
        )
        job.delegate = bad
        _ = job.run()
        #expect(flaky.base.contents("/u/f.txt") == "9999" && bad.errors.count == 1)
    }

    // MARK: F032, F044

    /// A delete the system refuses never unlocks or makes writable a file that is not locked, nor the target of a link.
    @Test
    internal func aRefusedDeleteNeverChangesTheTargetOfALinkOrAFileThatIsNotLocked() throws {
        let (fileSystems, _) = makeFileSystems()
        let key = try box.file("private/key.pem", "secret")
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: key.path)
        let plain = try box.file("locked/plain.txt", "x")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: plain.path)
        try FileManager.default.createSymbolicLink(at: box.url("locked/link"), withDestinationURL: key)
        // A locked folder refuses to let go of its entries with "operation not permitted".
        #expect(chflags(box.url("locked").path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(box.url("locked").path, 0) }
        let replies = Review2Replies()
        let job = FileJob(
            kind: .delete(toTrash: false),
            sources: [box.url("locked/link"), plain],
            fileSystems: fileSystems
        )
        job.options.asksAboutReadOnly = false
        job.delegate = replies
        let result = job.run()
        #expect(result.completed.isEmpty && replies.errors.count == 2)
        // Neither is locked itself: nobody is asked to unlock, and nothing is made writable.
        #expect(replies.locked == 0)
        #expect(
            Review2Stat.mode(key) == 0o400 && Review2Stat.mode(plain) == 0o444
                && FileIdentity.isSymlink(box.url("locked/link"))
        )
    }

    /// A locked file is unlocked and deleted when the user agrees to it.
    @Test
    internal func aLockedFileIsStillUnlockedAndDeletedWhenTheUserAgrees() throws {
        let (fileSystems, _) = makeFileSystems()
        let file = try box.file("d/locked.txt", "x")
        #expect(chflags(file.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(file.path, 0) }
        let replies = Review2Replies()
        let job = FileJob(kind: .delete(toTrash: false), sources: [file], fileSystems: fileSystems)
        job.delegate = replies
        #expect(job.run().completed.count == 1 && replies.locked == 1 && !box.exists("d/locked.txt"))
    }

    // MARK: F023, F072

    /// On a volume that keeps exact dates, a second and a half decides which file is newer.
    @Test
    internal func agesAreComparedExactlyWhereTheVolumesKeepThemExactly() throws {
        let (fileSystems, _) = makeFileSystems()
        // The scratch folder is on APFS on every Mac this runs on; on anything coarser the test says nothing.
        guard FileIdentity.timestampGrain(of: box.root) == 0 else {
            return
        }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try box.file("s/newer.txt", "new", modified: base.addingTimeInterval(1.5))
        try box.file("t/newer.txt", "old", modified: base)
        try box.file("s/same.txt", "new", modified: base)
        try box.file("t/same.txt", "old", modified: base.addingTimeInterval(1.5))
        var job = FileJob(
            kind: .copy,
            sources: [box.url("s/newer.txt")],
            target: TargetSpec(directory: box.url("t")),
            fileSystems: fileSystems
        )
        job.options.overwrite = .overwriteOlder
        _ = job.run()
        // A source that is a second and a half newer is newer.
        #expect(box.read("t/newer.txt") == "new")
        job = FileJob(
            kind: .copy,
            sources: [box.url("s/same.txt")],
            target: TargetSpec(directory: box.url("t")),
            fileSystems: fileSystems
        )
        job.options.overwrite = .overwriteOlderOrSame
        _ = job.run()
        // And a target that is a second and a half newer is not "of the same age".
        #expect(box.read("t/same.txt") == "old")
    }

    /// The tolerance of a date comparison is the grain of the volume; a place yet to be made answers for its folder.
    @Test
    internal func theGrainOfAVolumeDecidesTheTolerance() {
        let (_, memory) = makeFileSystems()
        #expect(FileIdentity.timestampGrain(of: memory.url("/a/b.txt")) == 2)
        // A place that does not exist yet answers for the folder above it.
        #expect(
            FileIdentity.timestampGrain(of: box.url("no/such/file.txt")) == FileIdentity.timestampGrain(of: box.root)
        )
    }

    // MARK: F019, F031

    /// A link back into a folder reached through another link is copied as a link, not followed in a loop.
    @Test
    internal func aLinkBackToAFolderItLiesInIsSeenThroughAnotherLink() throws {
        let (fileSystems, _) = makeFileSystems()
        try box.file("Y/f.txt", "inside")
        try FileManager.default.createSymbolicLink(atPath: box.url("Y/m").path, withDestinationPath: ".")
        try box.folder("s")
        try FileManager.default.createSymbolicLink(at: box.url("s/X"), withDestinationURL: box.url("Y"))
        try box.folder("t")
        let job = FileJob(
            kind: .copy,
            sources: [box.url("s")],
            target: TargetSpec(directory: box.url("t")),
            fileSystems: fileSystems
        )
        job.options.links = .followLinks
        let answers = Answers()
        job.delegate = answers
        let result = job.run()
        #expect(result.completed.count == 1 && answers.errors.isEmpty)
        // One copy of the folder; the link that leads back into it stays a link.
        #expect(box.read("t/s/X/f.txt") == "inside" && FileIdentity.isSymlink(box.url("t/s/X/m")))
        #expect(namesOnDisk(box.url("t/s/X")) == ["f.txt", "m"])
    }
}
