import AFMContracts
import AFMKernel
import Foundation
import ImageIO
import TestSupport
import Testing
import UniformTypeIdentifiers

@testable import MultiRenamePlugin

/// The session with odd lists and settings, the messages of a run, Undo and the result list.
@MainActor
extension CoverageRenameSession {
    // MARK: The result list

    /// A viewer that remembers what it was asked to show.
    private final class Viewer: ViewerService {
        var shown: [URL] = []

        func view(_ url: URL) { shown.append(url) }

        func view(text _: String, title _: String) {
            // Not asked for here.
        }

        deinit {
            // Nothing to release.
        }
    }

    // MARK: Odd lists and settings

    /// The same settings again change nothing.
    @Test
    internal func theSameSettingsAgainChangeNothing() {
        let session = session()
        var changes = 0
        session.onChange = { changes += 1 }
        session.settings = .unchanged
        #expect(changes == 0)
    }

    /// Moving rows that are not there moves nothing.
    @Test
    internal func movingRowsThatAreNotThereMovesNothing() {
        let session = session()
        #expect(session.move([7, 8], to: 0).isEmpty)
        #expect(session.rows.map(\.entry.name) == ["a.txt", "b.txt", "c.txt"])
    }

    /// "Next step" takes the given names as the old ones.
    @Test
    internal func nextStepTakesGivenNamesAsTheOldOnes() {
        let session = session()
        session.loadNames(fromText: "x.txt\ny.txt\nz.txt")
        session.nextStep()
        #expect(session.givenNames.isEmpty && session.rows.map(\.entry.name) == ["x.txt", "y.txt", "z.txt"])
        #expect(session.rows.allSatisfy { $0.status == .ready })
    }

    /// "Next step" puts the fields back to no change.
    @Test
    internal func nextStepGoesBackToNoChange() {
        let session = session()
        session.settings.nameMask = "[N]2"
        session.nextStep()
        #expect(session.settings == .unchanged && session.rows.map(\.entry.name) == ["a2.txt", "b2.txt", "c2.txt"])
    }

    /// Editing the names shows the old name where the masks give none.
    @Test
    internal func editingANameThatGivesNoNameShowsTheOldOne() {
        let session = session()
        session.settings.nameMask = "[X]"
        #expect(session.row(at: 0).newName == nil)
        interaction.formAnswers = [.cancel]
        session.editNames()
        let shown = interaction.forms.last?.first?.kind
        if case .multilineText(let text)? = shown {
            #expect(text == "a.txt\nb.txt\nc.txt")
        } else {
            Issue.record("no text of names was shown")
        }
    }

    /// Without a clipboard the optional placeholder `[X+]` is empty.
    @Test
    internal func withoutAClipboardTheOptionalPlaceholderIsEmpty() {
        let session = session()
        session.settings.nameMask = "[X+]n"
        #expect(session.row(at: 0).newName == "n.txt")
    }

    /// The date taken of a picture is read through the session's cache.
    @Test
    internal func theDateTakenIsReadThroughTheSession() throws {
        let file = box.url("p.jpg")
        let context = try #require(
            CGContext(
                data: nil,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        )
        let destination = try #require(
            CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        )
        let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2021:05:06 07:08:09"]
        CGImageDestinationAddImage(
            destination,
            try #require(context.makeImage()),
            [kCGImagePropertyExifDictionary: exif] as CFDictionary
        )
        #expect(CGImageDestinationFinalize(destination))
        let session = session([try #require(bench.kernel.fileSystems.item(at: file))])
        session.settings.nameMask = "[T4][Y]-[M]-[D]"
        #expect(session.row(at: 0).newName == "2021-05-06.jpg")
    }

    // MARK: Messages of a run

    /// Given names that move many files are shown in part.
    @Test
    internal func namesThatMoveManyFilesAreShownInPart() {
        let items = many(10)
        let session = session(items)
        session.loadNames(fromText: (0..<10).map { "sub/n\($0).txt" }.joined(separator: "\n"))
        session.start(completion: nil)
        let question = interaction.log.first { $0.hasPrefix("choose: 10 of the names given move") }
        #expect(question?.contains("sub/n7.txt\n…") == true)
        #expect(memory.allPaths.filter { $0.hasPrefix("/many/f") }.count == 10)
    }

    /// A given name that cannot be used is not asked about.
    @Test
    internal func aGivenNameThatCannotBeUsedIsNotAskedAbout() {
        let session = session()
        session.loadNames(fromText: "x/y.txt\nb.txt\n")
        interaction.choiceAnswers = [0]
        session.start(completion: nil)
        #expect(interaction.log.contains { $0.hasPrefix("choose: 1 of the names given move") })
        #expect(memory.allPaths.contains("/f/x/y.txt"))
    }

    /// Many conflicts are shown in part.
    @Test
    internal func manyConflictsAreShownInPart() {
        let session = session(many(13))
        session.settings.nameMask = "same"
        session.start(completion: nil)
        let question = interaction.log.first { $0.hasPrefix("choose: Name conflict: 13 file(s)") }
        #expect(question?.contains("same.txt\n…") == true)
    }

    /// A run where every rename fails keeps the list and gives no result list.
    @Test
    internal func aRunWhereEveryRenameFailsKeepsTheList() throws {
        try box.file("A/one.txt")
        try box.file("A/two.txt")
        let items = try ["one.txt", "two.txt"]
            .map { try #require(bench.kernel.fileSystems.item(at: box.url("A/" + $0))) }
        let session = session(items)
        // A file as a folder: nothing can be made below it.
        session.loadNames(fromText: "two.txt/x\none.txt/y")
        interaction.choiceAnswers = [0]
        var result: RenameRunResult?
        session.start { result = $0 }
        #expect(result?.renamed.isEmpty == true && result?.failures.count == 2 && session.rowCount == 2)
        #expect(!session.hasResultList)
    }

    /// Sixteen failures are told in part.
    @Test
    internal func sixteenFailuresAreCutShort() throws {
        let files = (0..<16).map { "f\($0).txt" }
        for name in files {
            try box.file("B/" + name)
        }
        try box.file("B/blocker")
        let items = try files.map { try #require(bench.kernel.fileSystems.item(at: box.url("B/" + $0))) }
        let session = session(items)
        session.loadNames(fromText: files.map { "blocker/" + $0 }.joined(separator: "\n"))
        interaction.choiceAnswers = [0]
        session.start(completion: nil)
        #expect(interaction.log.contains("inform: 16 file(s) could not be renamed!"))
    }

    /// Names that cannot be used are told after the run.
    @Test
    internal func namesThatCannotBeUsedAreToldAfterTheRun() {
        let session = session()
        session.loadNames(fromText: "x.txt\n..\n")
        session.start(completion: nil)
        #expect(names.contains("x.txt") && interaction.log.contains { $0.contains("1 file(s) were left out") })
    }

    // MARK: Undo

    /// Undo needs something to undo.
    @Test
    internal func undoNeedsSomethingToUndo() {
        let session = session()
        session.undo(completion: nil)
        #expect(interaction.log.isEmpty && !session.isBusy)
    }

    /// A count of runs without the runs undoes nothing.
    @Test
    internal func aCountWithoutRunsUndoesNothing() {
        settings.set(1, forKey: "multirename.undoCount")
        let session = session()
        #expect(session.canUndo)
        session.undo(completion: nil)
        #expect(interaction.log.isEmpty && !session.isBusy)
    }

    /// A long run is shown in part when it is to be undone.
    @Test
    internal func aLongRunIsShownInPartWhenUndone() {
        let session = session(many(21))
        session.settings.nameMask = "u[C]"
        session.start(completion: nil)
        session.undo(completion: nil)
        #expect(interaction.log.last?.hasSuffix("… (21 files)") == true)
    }

    /// The result list needs a run.
    @Test
    internal func theResultListNeedsARun() {
        session().showResultList()
        #expect(interaction.log.isEmpty)
    }

    /// The result list goes to the viewer, or else to the View command.
    @Test
    internal func theResultListGoesToTheViewerOrTheViewCommand() {
        let session = session()
        session.settings.nameMask = "x[N]"
        session.start(completion: nil)
        var viewed: [CommandArgument] = []
        bench.kernel.commands.register(Command(.view, "View")) { argument in viewed.append(argument) }
        session.showResultList()
        #expect(viewed.count == 1 && !interaction.log.contains("form: Result list"))
        let viewer = Viewer()
        bench.kernel.services.register((any ViewerService).self, viewer)
        session.showResultList()
        #expect(viewer.shown == [session.logURL] && viewed.count == 1)
    }
}
