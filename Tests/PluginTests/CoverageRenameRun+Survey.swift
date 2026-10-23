import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import MultiRenamePlugin

/// The survey of the folders: letter case, what they hold, and the previews that use it.
extension CoverageRenameRun {
    // MARK: Letter case

    /// A name in capitals is tried in small letters.
    @Test
    internal func aNameInCapitalsIsTriedInSmallLetters() throws {
        let file = try box.file("README")
        let item = try #require(registry.item(at: file))
        #expect(RenameSurvey(fileSystems: registry).foldsCase([item]))
    }

    /// A survey that is cancelled finds no folding of letter case.
    @Test
    internal func aCancelledSurveyFoldsNothing() throws {
        let file = try box.file("notes.txt")
        let item = try #require(registry.item(at: file))
        let cancellation = CancellationFlag()
        cancellation.cancel()
        #expect(!RenameSurvey(fileSystems: registry, cancellation: cancellation).foldsCase([item]))
    }

    /// Off the local disk the folder is listed: a server that finds `NOTES.TXT` for `notes.txt`
    /// folds letter case, unless it holds both spellings.
    @Test
    internal func aServerIsAskedByListingTheFolder() throws {
        fileSystem.foldsCase = true
        fileSystem.base.addFile("/s/notes.txt", "abc")
        let item = try #require(registry.item(at: url("/s/notes.txt")))
        #expect(RenameSurvey(fileSystems: registry).foldsCase([item]))
        #expect(RenameSurvey(fileSystems: registry, cancellation: CancellationFlag()).foldsCase([item]))
        fileSystem.foldsCase = false
        fileSystem.base.addFile("/s/NOTES.TXT", "other")
        #expect(!RenameSurvey(fileSystems: registry).foldsCase([item]))
        #expect(!RenameSurvey(fileSystems: registry, cancellation: CancellationFlag()).foldsCase([item]))
    }

    /// A file with a second name (a hard link) is asked by listing its folder too.
    @Test
    internal func aFileWithTwoNamesIsAskedByListing() throws {
        let file = try box.file("linked.txt")
        try FileManager.default.linkItem(at: file, to: box.url("other.txt"))
        let item = try #require(registry.item(at: file))
        #expect(RenameSurvey(fileSystems: registry).foldsCase([item]))
    }

    /// The volume answers for folders away from the list, also for one that is not there yet; a server
    /// does not.
    @Test
    internal func theVolumeAnswersForFoldersAwayFromTheList() {
        #expect(RenameSurvey.volumeCaseFolding(url("/x")) == nil)
        let missing = box.url("not/there/yet")
        #expect(RenameSurvey.volumeCaseFolding(missing) == RenameSurvey.volumeCaseFolding(box.root))
        #expect(RenameSurvey.volumeCaseFolding(box.root) != nil)
    }

    /// No folders hold nothing.
    @Test
    internal func noFoldersHoldNothing() {
        let keys = RenameSurvey(fileSystems: registry).existingKeys(in: [:], planner: RenamePlanner()) { false }
        #expect(keys.isEmpty)
    }

    /// A list of items on the local disk and on a server that tells the cases apart: only the
    /// folder on the disk folds them.
    @Test
    internal func eachFolderIsJudgedOnItsOwn() throws {
        let local = try box.file("a.txt")
        let remote = fileSystem.base.addFile("/r/b.txt")
        let entries = try [local, remote].map { RenameEntry(try #require(registry.item(at: $0))) }
        var settings = RenameSettings()
        settings.nameMask = "X[N]"
        let preview = RenameComputation.preview(
            RenameRequest(entries: entries, settings: settings, context: RenameContext()),
            fileSystems: registry,
            cache: RenameCache(),
            cancellation: nil
        ) { false }
        #expect(preview.planner.key(box.url("A.TXT")) == preview.planner.key(box.url("a.txt")))
        #expect(preview.planner.key(url("/r/B.TXT")) != preview.planner.key(url("/r/b.txt")))
    }

    /// A name given with a slash in front moves the item from the top of its file system; the
    /// folder it goes to is not near any of the list, and its volume is asked.
    @Test
    internal func aNameFromTheTopGoesElsewhere() throws {
        let file = try box.file("a/one.txt")
        let entry = RenameEntry(try #require(registry.item(at: file)))
        let target = RenameComputation.target(of: entry, named: box.url("b/two.txt").path)
        #expect(target.path == box.url("b/two.txt").path)
        let preview = RenameComputation.preview(
            RenameRequest(
                entries: [entry],
                settings: RenameSettings(),
                context: RenameContext(),
                given: [box.url("b/two.txt").path]
            ),
            fileSystems: registry,
            cache: RenameCache(),
            cancellation: nil
        ) { false }
        #expect(preview.statuses == [.ready] && preview.targets.first??.lastPathComponent == "two.txt")
        let remote = RenameEntry(try #require(registry.item(at: fileSystem.base.addFile("/r/s/x.txt"))))
        #expect(RenameComputation.target(of: remote, named: "/t/y.txt") == url("/t/y.txt"))
    }

    /// Accents written another way on the local disk: the name is put into the folder as typed.
    @Test
    internal func accentsWrittenAnotherWayKeepTheirForm() throws {
        let file = try box.file("e\u{301}.txt")
        let entry = RenameEntry(FileItem(url: file, name: "e\u{301}.txt"))
        let target = RenameComputation.target(of: entry, named: "\u{E9}.txt")
        #expect(target.lastPathComponent.unicodeScalars.count == 5)
    }

    /// A preview that is cancelled once the planner is made does not list the folders.
    @Test
    internal func aPreviewCancelledAfterThePlannerListsNothing() {
        fileSystem.base.addFile("/p/a.txt")
        fileSystem.base.addFile("/p/b.txt")
        let entries = ["/p/a.txt"].compactMap { registry.item(at: url($0)) }.map(RenameEntry.init)
        var settings = RenameSettings()
        settings.nameMask = "b"
        let asked = Asked()
        let preview = RenameComputation.preview(
            RenameRequest(entries: entries, settings: settings, context: RenameContext()),
            fileSystems: registry,
            cache: RenameCache(),
            cancellation: nil
        ) { asked.next() >= 3 }
        // Not compared with b.txt, which is there: the conflict is not found.
        #expect(preview.statuses == [.ready] && preview.existing.isEmpty)
    }

    /// A listing that is cut short by the cancellation counts for nothing.
    @Test
    internal func aListingCutShortHoldsNothing() {
        fileSystem.base.addFile("/q/a.txt")
        let cancellation = CancellationFlag()
        let keys = RenameSurvey(fileSystems: registry, cancellation: cancellation)
            .existingKeys(in: ["q": url("/q/")], planner: RenamePlanner()) {
                cancellation.cancel()
                return false
            }
        #expect(keys.isEmpty)
    }
}
