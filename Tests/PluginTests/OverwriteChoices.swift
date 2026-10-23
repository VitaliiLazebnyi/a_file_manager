import FileOperationsPlugin
import Foundation
import TestSupport
import Testing

/// Every answer of the Overwrite dialog and every preset of the Copy dialog.
@Suite
internal struct OverwriteChoices {
    /// The scratch folder: sources in A, the files they meet in B.
    internal let box: Sandbox
    /// The older of the two dates the files carry.
    internal let old = Date(timeIntervalSince1970: 1_600_000_000)
    /// The newer of the two dates the files carry.
    internal let new = Date(timeIntervalSince1970: 1_700_000_000)

    /// A/one.txt (newer and larger than its target) and A/two.txt (older and smaller).
    internal var sources: [URL] { [box.url("A/one.txt"), box.url("A/two.txt")] }
    /// The folder B, where both names are taken.
    internal var target: TargetSpec { TargetSpec(directory: box.url("B")) }

    /// Two sources whose names are taken in the target, with other ages and sizes.
    internal init() throws {
        box = try Sandbox()
        try box.file("A/one.txt", "source one", modified: new)
        try box.file("A/two.txt", "s2", modified: old)
        try box.file("B/one.txt", "target", modified: old)
        try box.file("B/two.txt", "target two", modified: new)
    }

    /// Overwrite and Skip answer for one file each: the next name taken is asked about again.
    @Test
    internal func overwriteAndSkipAreForOneFileEach() {
        let replies = Replies(.overwrite, .skip)
        let result = replies.run(.copy, sources, to: target, fileSystems: makeFileSystems().0, configure: nil)
        #expect(replies.conflicts == ["one.txt", "two.txt"])
        #expect(box.read("B/one.txt") == "source one" && box.read("B/two.txt") == "target two")
        #expect(result.completed.map(\.lastPathComponent) == ["one.txt"])
    }

    /// Overwrite All and Skip All are asked once and then hold for the rest of the job.
    @Test
    internal func overwriteAllAndSkipAllAskOnce() {
        let all = Replies(.overwriteAll)
        all.run(.copy, sources, to: target, fileSystems: makeFileSystems().0, configure: nil)
        #expect(all.conflicts == ["one.txt"] && box.read("B/two.txt") == "s2")
        let none = Replies(.skipAll)
        try? "again".write(to: box.url("A/one.txt"), atomically: true, encoding: .utf8)
        none.run(.copy, sources, to: target, fileSystems: makeFileSystems().0, configure: nil)
        #expect(none.conflicts == ["one.txt"] && box.read("B/one.txt") == "source one")
    }

    /// A new name that is taken as well brings the question again, about that name.
    @Test
    internal func renameAsksAgainWhenTheNewNameIsTakenToo() {
        let replies = Replies(.rename("two.txt"), .rename("fresh.txt"), .skip)
        replies.run(.copy, [box.url("A/one.txt")], to: target, fileSystems: makeFileSystems().0, configure: nil)
        #expect(replies.conflicts == ["one.txt", "two.txt"])
        #expect(
            box.read("B/fresh.txt") == "source one" && box.read("B/one.txt") == "target"
                && box.read("B/two.txt") == "target two"
        )
    }

    /// Rename Existing gives the old file the new name, and the source arrives under its own.
    @Test
    internal func renameExistingMovesTheTargetAsideFirst() {
        let result = Replies(.renameExisting("one.old"))
            .run(.copy, [box.url("A/one.txt")], to: target, fileSystems: makeFileSystems().0, configure: nil)
        #expect(box.read("B/one.old") == "target" && box.read("B/one.txt") == "source one")
        #expect(result.lastTarget?.lastPathComponent == "one.txt")
    }

    /// Auto-rename Copied asks once and gives every later copy a numbered name too.
    @Test
    internal func autoRenameCopiedHoldsForTheRestOfTheJob() {
        let replies = Replies(.autoRenameCopied)
        let result = replies.run(.copy, sources, to: target, fileSystems: makeFileSystems().0, configure: nil)
        #expect(replies.conflicts == ["one.txt"])
        #expect(box.read("B/one (2).txt") == "source one" && box.read("B/two (2).txt") == "s2")
        #expect(box.read("B/one.txt") == "target" && result.lastTarget?.lastPathComponent == "two (2).txt")
    }

    /// Auto-rename Existing moves each old file to a numbered name before the copy takes its place.
    @Test
    internal func autoRenameExistingKeepsTheOldFilesUnderNumberedNames() {
        Replies(.autoRenameExisting).run(.copy, sources, to: target, fileSystems: makeFileSystems().0, configure: nil)
        #expect(box.read("B/one (2).txt") == "target" && box.read("B/one.txt") == "source one")
        #expect(box.read("B/two (2).txt") == "target two" && box.read("B/two.txt") == "s2")
    }

    /// Copy All Larger, Copy All Smaller, Overwrite All Older and Overwrite All Older or Same each keep the file the
    /// rule says.
    @Test
    internal func theRulesByAgeAndSize() throws {
        // one.txt: the source is newer and larger; two.txt: older and smaller.
        Replies(.copyAllLarger).run(.copy, sources, to: target, fileSystems: makeFileSystems().0, configure: nil)
        #expect(box.read("B/one.txt") == "source one" && box.read("B/two.txt") == "target two")
        try box.file("B/one.txt", "target", modified: old)
        Replies(.copyAllSmaller).run(.copy, sources, to: target, fileSystems: makeFileSystems().0, configure: nil)
        #expect(box.read("B/one.txt") == "target" && box.read("B/two.txt") == "s2")

        try box.file("B/two.txt", "same age", modified: old)
        Replies(.overwriteAllOlder).run(.copy, sources, to: target, fileSystems: makeFileSystems().0, configure: nil)
        #expect(box.read("B/one.txt") == "source one" && box.read("B/two.txt") == "same age")
        Replies(.overwriteAllOlderOrSame)
            .run(.copy, [box.url("A/two.txt")], to: target, fileSystems: makeFileSystems().0, configure: nil)
        #expect(box.read("B/two.txt") == "s2")
    }

    /// Rename Older, Skip Newer keeps an older target under a numbered name and leaves a newer one alone.
    @Test
    internal func renameOlderSkipNewer() {
        Replies(.renameOlderSkipNewer).run(.copy, sources, to: target, fileSystems: makeFileSystems().0, configure: nil)
        #expect(box.read("B/one (2).txt") == "target" && box.read("B/one.txt") == "source one")
        #expect(box.read("B/two.txt") == "target two" && !box.exists("B/two (2).txt"))
    }

    /// Cancel ends the job before anything in the target has changed.
    @Test
    internal func cancelLeavesEverythingAsItWas() {
        let result = Replies(.cancel).run(.copy, sources, to: target, fileSystems: makeFileSystems().0, configure: nil)
        #expect(
            result.cancelled && box.read("B/one.txt") == "target"
                && namesOnDisk(box.url("B")) == ["one.txt", "two.txt"]
        )
    }

    /// A preset of the Copy dialog answers every conflict without a question.
    @Test
    internal func aPresetAnswersWithoutAsking() {
        // Each preset, with what B/one.txt and B/two.txt then hold.
        let presets: KeyValuePairs<OverwriteMode, (String, String)> = [
            .skipAll: ("target", "target two"), .overwriteOlder: ("source one", "target two"),
            .overwriteAll: ("source one", "s2")
        ]
        for (mode, (one, two)) in presets {
            _ = try? box.file("B/one.txt", "target", modified: old)
            _ = try? box.file("B/two.txt", "target two", modified: new)
            let replies = Replies()
            replies.run(.copy, sources, to: target, fileSystems: makeFileSystems().0) { job in
                job.options.overwrite = mode
            }
            #expect(
                replies.conflicts.isEmpty && box.read("B/one.txt") == one && box.read("B/two.txt") == two,
                "\(mode)"
            )
        }
        let replies = Replies()
        replies.run(.copy, sources, to: target, fileSystems: makeFileSystems().0) { job in
            job.options.overwrite = .autoRenameCopied
        }
        #expect(replies.conflicts.isEmpty && box.read("B/one (2).txt") == "source one")
    }

    /// Append adds the source's contents to the end of the target and leaves the source as it was.
    @Test
    internal func appendAddsTheSourceToTheEndOfTheTarget() {
        let result = Replies(.append)
            .run(.copy, [box.url("A/one.txt")], to: target, fileSystems: makeFileSystems().0, configure: nil)
        #expect(box.read("B/one.txt") == "targetsource one" && box.read("A/one.txt") == "source one")
        #expect(result.completed.count == 1 && namesOnDisk(box.url("B")) == ["one.txt", "two.txt"])
    }

    /// Resume writes the rest of a shorter target, with the source's date and rights, and refuses a target that is
    /// not shorter.
    @Test
    internal func resumeContinuesAPartialFile() throws {
        let (fileSystems, memory) = makeFileSystems()
        memory.addFile("/out/big.bin", "0123456789", modified: new, permissions: 0o600)
        try box.file("B/big.bin", "0123", modified: old)
        let result = Replies(.resume)
            .run(.copy, [memory.url("/out/big.bin")], to: target, fileSystems: fileSystems) { job in
                job.options.verifies = true
            }
        #expect(result.completed.count == 1 && box.read("B/big.bin") == "0123456789")
        let attributes = try FileManager.default.attributesOfItem(atPath: box.url("B/big.bin").path)
        #expect(attributes[.modificationDate] as? Date == new && attributes[.posixPermissions] as? Int == 0o600)
        #expect(namesOnDisk(box.url("B")) == ["big.bin", "one.txt", "two.txt"])

        // A target that is not shorter than the source is no partial copy of it.
        let replies = Replies(.resume)
        replies.run(.copy, [memory.url("/out/big.bin")], to: target, fileSystems: fileSystems, configure: nil)
        #expect(replies.errors.count == 1 && replies.errors[0].contains("cannot be resumed"))
    }

    /// A move asks about a taken name like a copy, and a skipped file stays where it was.
    @Test
    internal func aMoveOntoAnExistingNameAsksToo() {
        let replies = Replies(.overwrite, .skip)
        let result = replies.run(.move, sources, to: target, fileSystems: makeFileSystems().0, configure: nil)
        #expect(!box.exists("A/one.txt") && box.read("B/one.txt") == "source one")
        #expect(box.exists("A/two.txt") && box.read("B/two.txt") == "target two" && result.completed.count == 1)
    }
}
