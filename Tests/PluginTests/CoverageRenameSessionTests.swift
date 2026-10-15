import AFMContracts
import AFMKernel
import Foundation
import ImageIO
import LocalFileSystemPlugin
import TestSupport
import Testing
import UniformTypeIdentifiers

@testable import MultiRenamePlugin

/// The session of the Multi-Rename Tool where it is busy, cancelled or given unusual lists:
/// what is refused while a run is under way, long lists worked on in the background, runs that
/// are cancelled, and messages that are cut short.
@MainActor @Suite struct CoverageRenameSession {
    let memory = MemoryFileSystem()
    let box: Sandbox
    let settings = MemorySettings()
    let bench: TestBench
    /// Holds or cancels the jobs of the tests that attach it.
    let jobs: CancellingJobService

    var ui: ScriptedInteraction { bench.interaction }

    init() throws {
        box = try Sandbox()
        for name in ["a.txt", "b.txt", "c.txt"] { memory.addFile("/f/" + name, name) }
        bench = TestBench(
            plugins: [],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/f"),
            right: memory.url("/f"),
            settings: settings
        )
        jobs = CancellingJobService(moment: .never, panels: bench.panelSet)
    }

    /// A session on the given items (the left panel's when none are given).
    func session(
        _ items: [FileItem]? = nil,
        inBackground: Bool = false,
        clipboard: (@Sendable () -> String?)? = nil
    ) -> MultiRenameSession {
        let items = items ?? bench.left.model.items
        let store = RenameStore(settings: settings)
        let log = box.url("log")
        guard let clipboard else {
            return MultiRenameSession(
                kernel: bench.kernel,
                items: items,
                store: store,
                settings: .unchanged,
                logDirectory: log,
                previewsInBackground: inBackground
            )
        }
        return MultiRenameSession(
            kernel: bench.kernel,
            items: items,
            store: store,
            settings: .unchanged,
            logDirectory: log,
            previewsInBackground: inBackground,
            clipboard: clipboard
        )
    }

    /// `count` files in a folder of their own.
    func many(_ count: Int, in folder: String = "/many") -> [FileItem] {
        (0..<count).map { FileItem(url: memory.addFile("\(folder)/f\($0).txt"), name: "f\($0).txt") }
    }

    /// Lets jobs run through `jobs`, at `moment`.
    func attachJobs(_ moment: CancellingJobService.Moment) {
        jobs.moment = moment
        bench.kernel.attach(jobs)
    }

    var names: [String] { memory.allPaths.filter { $0.hasPrefix("/f/") }.map { String($0.dropFirst(3)) } }

    // MARK: While a run is under way

    @Test func theListStaysAsItIsWhileARunIsUnderWay() {
        attachJobs(.held)
        let session = session()
        session.settings.nameMask = "x[N]"
        session.start()
        #expect(session.isBusy && jobs.heldCount == 1 && !session.canUndo)
        let before = session.rows.map(\.entry.name)
        session.sort(by: .name, ascending: false)
        session.move([0], by: 1)
        #expect(session.move([0], to: 3) == [0])
        session.remove([0])
        session.nextStep()
        session.loadNames(fromText: "z")
        session.loadNames(from: memory.url("/f/a.txt"))
        session.editNames()
        session.clearGivenNames()
        session.start()
        session.undo()
        #expect(session.rows.map(\.entry.name) == before && session.givenNames == nil && jobs.heldCount == 1)
        #expect(!ui.log.contains { $0.hasPrefix("form:") })
        jobs.runHeld()
        #expect(!session.isBusy && names == ["xa.txt", "xb.txt", "xc.txt"])
    }

    // MARK: Cancelled runs

    @Test func aRunCancelledAtOnceRenamesNothing() {
        attachJobs(.atStart)
        let session = session()
        session.settings.nameMask = "x[N]"
        var result: RenameRunResult?
        session.start { result = $0 }
        #expect(result?.cancelled == true && names == ["a.txt", "b.txt", "c.txt"] && session.rowCount == 3)
    }

    @Test func aRunCancelledWhileAskingAboutConflictsRenamesNothing() {
        attachJobs(.afterQuestion(1))
        let session = session()
        session.settings.nameMask = "same"
        ui.choiceAnswers = [0]
        var result: RenameRunResult?
        session.start { result = $0 }
        #expect(result?.cancelled == true && names == ["a.txt", "b.txt", "c.txt"])
        #expect(!ui.log.contains { $0.hasPrefix("inform:") })
    }

    /// An Undo cancelled before anything was put back keeps the run, so it can be undone later.
    @Test func anUndoCancelledAtOnceKeepsTheRun() {
        let session = session()
        session.settings.nameMask = "x[N]"
        session.start()
        attachJobs(.atStart)
        ui.choiceAnswers = [0]
        var attempted: [RenamedItem]?
        session.undo { attempted = $0 }
        #expect(names == ["xa.txt", "xb.txt", "xc.txt"] && attempted?.count == 3)
        #expect(session.canUndo && session.store.lastUndo?.count == 3)
        #expect(!ui.log.contains { $0.hasPrefix("inform:") })
        // Asked again, it puts the files back.
        attachJobs(.never)
        ui.choiceAnswers = [0]
        session.undo()
        #expect(names == ["a.txt", "b.txt", "c.txt"] && !session.canUndo)
    }

    // MARK: Long lists in the background

    @Test func nextStepOfALongListIsMadeInTheBackground() async {
        let session = session(many(2_000), inBackground: true)
        session.settings.nameMask = "g[C]"
        #expect(await RunLoopWait.until { !session.isComputing })
        session.nextStep()
        #expect(await RunLoopWait.until { session.row(at: 0).entry.name == "g1.txt" && !session.isComputing })
        #expect(session.settings == .unchanged && session.row(at: 1_999).entry.name == "g2000.txt")
    }

    @Test func aNextStepOvertakenByAChangeOfTheListIsDropped() async {
        let session = session(many(2_000), inBackground: true)
        session.settings.nameMask = "g[C]"
        #expect(await RunLoopWait.until { !session.isComputing })
        session.nextStep()
        // The list changes before the step is back: the step was made for the old list.
        session.loadNames(fromText: "first")
        #expect(await RunLoopWait.until { !session.isComputing })
        #expect(session.row(at: 0).entry.name == "f0.txt" && session.givenNames == ["first"])
    }

    @Test func theNamesOfALongListAreEditedFromTheBackground() async {
        let session = session(many(2_000), inBackground: true)
        // No name for any of them: the text holds the old names.
        session.settings.nameMask = "[X]"
        #expect(await RunLoopWait.until { !session.isComputing && session.row(at: 0).newName == nil })
        ui.formAnswers = [.values(["names": .text("one\ntwo")])]
        session.editNames()
        #expect(await RunLoopWait.until { session.givenNames == ["one", "two"] })
        #expect(ui.log.contains("form: Edit names"))
    }

    /// The text of the first edit was made for the list before a change: only the second edit,
    /// made for the list as it is, is shown.
    @Test func anEditOfALongListThatIsOvertakenIsDropped() async {
        let session = session(many(2_000), inBackground: true)
        session.editNames()
        session.clearGivenNames()
        ui.formAnswers = [.values(["names": .text("second")])]
        session.editNames()
        #expect(await RunLoopWait.until { session.givenNames == ["second"] })
        #expect(ui.log.filter { $0 == "form: Edit names" }.count == 1)
    }

    @Test func namesAreLoadedFromAFileInTheBackground() async {
        memory.addFile("/lists/names.txt", "one\ntwo\nthree")
        let session = session(inBackground: true)
        var loaded = false
        session.loadNames(from: memory.url("/lists/names.txt")) { loaded = true }
        #expect(await RunLoopWait.until { loaded })
        #expect(session.givenNames == ["one", "two", "three"])
    }

    @Test func anEmptyListOfNamesGivesTheMasksBack() {
        let session = session()
        session.loadNames(fromText: "x")
        #expect(session.givenNames == ["x"])
        session.loadNames(fromText: "\n\n")
        #expect(session.givenNames == nil)
    }

    @Test func anUndoInTheBackgroundDecodesTheRunsFirst() async {
        let session = session(inBackground: true)
        session.settings.nameMask = "x[N]"
        session.start()
        #expect(names == ["xa.txt", "xb.txt", "xc.txt"])
        ui.choiceAnswers = [0]
        var attempted: [RenamedItem]?
        session.undo { attempted = $0 }
        #expect(await RunLoopWait.until { attempted != nil })
        #expect(names == ["a.txt", "b.txt", "c.txt"])
    }

    // MARK: Odd lists and settings

    @Test func theSameSettingsAgainChangeNothing() {
        let session = session()
        var changes = 0
        session.onChange = { changes += 1 }
        session.settings = .unchanged
        #expect(changes == 0)
    }

    @Test func movingRowsThatAreNotThereMovesNothing() {
        let session = session()
        #expect(session.move([7, 8], to: 0).isEmpty)
        #expect(session.rows.map(\.entry.name) == ["a.txt", "b.txt", "c.txt"])
    }

    @Test func nextStepTakesGivenNamesAsTheOldOnes() {
        let session = session()
        session.loadNames(fromText: "x.txt\ny.txt\nz.txt")
        session.nextStep()
        #expect(session.givenNames == nil && session.rows.map(\.entry.name) == ["x.txt", "y.txt", "z.txt"])
        #expect(session.rows.allSatisfy { $0.status == .ready })
    }

    @Test func nextStepGoesBackToNoChange() {
        let session = session()
        session.settings.nameMask = "[N]2"
        session.nextStep()
        #expect(session.settings == .unchanged && session.rows.map(\.entry.name) == ["a2.txt", "b2.txt", "c2.txt"])
    }

    @Test func editingANameThatGivesNoNameShowsTheOldOne() {
        let session = session()
        session.settings.nameMask = "[X]"
        #expect(session.row(at: 0).newName == nil)
        ui.formAnswers = [.cancel]
        session.editNames()
        let shown = ui.forms.last?.first?.kind
        if case .multilineText(let text)? = shown {
            #expect(text == "a.txt\nb.txt\nc.txt")
        } else {
            Issue.record("no text of names was shown")
        }
    }

    @Test func withoutAClipboardTheOptionalPlaceholderIsEmpty() {
        let session = session()
        session.settings.nameMask = "[X+]n"
        #expect(session.row(at: 0).newName == "n.txt")
    }

    @Test func theDateTakenIsReadThroughTheSession() throws {
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

    @Test func namesThatMoveManyFilesAreShownInPart() {
        let items = many(10)
        let session = session(items)
        session.loadNames(fromText: (0..<10).map { "sub/n\($0).txt" }.joined(separator: "\n"))
        session.start()
        let question = ui.log.first { $0.hasPrefix("choose: 10 of the names given move") }
        #expect(question?.contains("sub/n7.txt\n…") == true)
        #expect(memory.allPaths.filter { $0.hasPrefix("/many/f") }.count == 10)
    }

    @Test func aGivenNameThatCannotBeUsedIsNotAskedAbout() {
        let session = session()
        session.loadNames(fromText: "x/y.txt\nb.txt\n")
        ui.choiceAnswers = [0]
        session.start()
        #expect(ui.log.contains { $0.hasPrefix("choose: 1 of the names given move") })
        #expect(memory.allPaths.contains("/f/x/y.txt"))
    }

    @Test func manyConflictsAreShownInPart() {
        let session = session(many(13))
        session.settings.nameMask = "same"
        session.start()
        let question = ui.log.first { $0.hasPrefix("choose: Name conflict: 13 file(s)") }
        #expect(question?.contains("same.txt\n…") == true)
    }

    @Test func aRunWhereEveryRenameFailsKeepsTheList() throws {
        try box.file("A/one.txt")
        try box.file("A/two.txt")
        let items = try ["one.txt", "two.txt"]
            .map { try #require(bench.kernel.fileSystems.item(at: box.url("A/" + $0))) }
        let session = session(items)
        // A file as a folder: nothing can be made below it.
        session.loadNames(fromText: "two.txt/x\none.txt/y")
        ui.choiceAnswers = [0]
        var result: RenameRunResult?
        session.start { result = $0 }
        #expect(result?.renamed.isEmpty == true && result?.failures.count == 2 && session.rowCount == 2)
        #expect(!session.hasResultList)
    }

    @Test func sixteenFailuresAreCutShort() throws {
        let names = (0..<16).map { "f\($0).txt" }
        for name in names { try box.file("B/" + name) }
        try box.file("B/blocker")
        let items = try names.map { try #require(bench.kernel.fileSystems.item(at: box.url("B/" + $0))) }
        let session = session(items)
        session.loadNames(fromText: names.map { "blocker/" + $0 }.joined(separator: "\n"))
        ui.choiceAnswers = [0]
        session.start()
        #expect(ui.log.contains("inform: 16 file(s) could not be renamed!"))
    }

    @Test func namesThatCannotBeUsedAreToldAfterTheRun() {
        let session = session()
        session.loadNames(fromText: "x.txt\n..\n")
        session.start()
        #expect(names.contains("x.txt") && ui.log.contains { $0.contains("1 file(s) were left out") })
    }

    // MARK: Undo

    @Test func undoNeedsSomethingToUndo() {
        let session = session()
        session.undo()
        #expect(ui.log.isEmpty && !session.isBusy)
    }

    @Test func aCountWithoutRunsUndoesNothing() {
        settings.set(1, forKey: "multirename.undoCount")
        let session = session()
        #expect(session.canUndo)
        session.undo()
        #expect(ui.log.isEmpty && !session.isBusy)
    }

    @Test func aLongRunIsShownInPartWhenUndone() {
        let session = session(many(21))
        session.settings.nameMask = "u[C]"
        session.start()
        session.undo()
        #expect(ui.log.last?.hasSuffix("… (21 files)") == true)
    }

    // MARK: The result list

    /// A viewer that remembers what it was asked to show.
    private final class Viewer: ViewerService {
        var shown: [URL] = []
        func view(_ url: URL) { shown.append(url) }
        func view(text _: String, title _: String) {
            // Not asked for here.
        }
    }

    @Test func theResultListNeedsARun() {
        session().showResultList()
        #expect(ui.log.isEmpty)
    }

    @Test func theResultListGoesToTheViewerOrTheViewCommand() {
        let session = session()
        session.settings.nameMask = "x[N]"
        session.start()
        var viewed: [CommandArgument] = []
        bench.kernel.commands.register(Command(.view, "View"), parameterized: { viewed.append($0) })
        session.showResultList()
        #expect(viewed.count == 1 && !ui.log.contains("form: Result list"))
        let viewer = Viewer()
        bench.kernel.services.register((any ViewerService).self, viewer)
        session.showResultList()
        #expect(viewer.shown == [session.logURL] && viewed.count == 1)
    }
}
