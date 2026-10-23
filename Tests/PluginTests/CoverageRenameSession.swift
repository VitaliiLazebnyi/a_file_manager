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
@MainActor
@Suite
internal struct CoverageRenameSession {
    /// The memory the files of the list are in, `/f/a.txt` to `/f/c.txt`.
    internal let memory = MemoryFileSystem()
    /// A folder of the test's own on the local disk.
    internal let box: Sandbox
    /// The settings the store keeps its values in.
    internal let settings = MemorySettings()
    /// The kernel with both panels in `/f`.
    internal let bench: TestBench
    /// Holds or cancels the jobs of the tests that attach it.
    internal let jobs: CancellingJobService

    /// The questions and messages of the bench, answered as the test says.
    internal var interaction: ScriptedInteraction { bench.interaction }

    /// The names in `/f`, as they are now.
    internal var names: [String] { memory.allPaths.filter { $0.hasPrefix("/f/") }.map { String($0.dropFirst(3)) } }

    /// Three files in `/f` of the memory, shown in both panels.
    internal init() throws {
        box = try Sandbox()
        for name in ["a.txt", "b.txt", "c.txt"] {
            memory.addFile("/f/" + name, name)
        }
        bench = TestBench(
            plugins: [],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/f"),
            right: memory.url("/f"),
            settings: settings
        )
        jobs = CancellingJobService(moment: .never, panels: bench.panelSet)
    }

    /// A session on the items of the left panel, with the previews made at once.
    internal func session() -> MultiRenameSession {
        session(bench.left.model.items, inBackground: false)
    }

    /// A session on `items`, with the previews made at once.
    internal func session(_ items: [FileItem]) -> MultiRenameSession {
        session(items, inBackground: false)
    }

    /// A session on the items of the left panel, with the previews in the background or at once.
    internal func session(inBackground: Bool) -> MultiRenameSession {
        session(bench.left.model.items, inBackground: inBackground)
    }

    /// A session on `items`, with an empty clipboard and the previews in the background or at once.
    internal func session(_ items: [FileItem], inBackground: Bool) -> MultiRenameSession {
        MultiRenameSession(
            kernel: bench.kernel,
            items: items,
            store: RenameStore(settings: settings),
            settings: .unchanged,
            logDirectory: box.url("log"),
            previewsInBackground: inBackground,
            clipboard: { nil },
            clipboardChangeCount: nil
        )
    }

    /// `count` files in `/many`, a folder of their own.
    internal func many(_ count: Int) -> [FileItem] {
        (0..<count).map { FileItem(url: memory.addFile("/many/f\($0).txt"), name: "f\($0).txt") }
    }

    /// Lets jobs run through `jobs`, at `moment`.
    internal func attachJobs(_ moment: CancellingJobService.Moment) {
        jobs.moment = moment
        bench.kernel.attach(jobs)
    }

    // MARK: While a run is under way

    /// The list stays as it is while a run is under way: nothing that changes it is done.
    @Test
    internal func theListStaysAsItIsWhileARunIsUnderWay() {
        attachJobs(.held)
        let session = session()
        session.settings.nameMask = "x[N]"
        session.start(completion: nil)
        #expect(session.isBusy && jobs.heldCount == 1 && !session.canUndo)
        let before = session.rows.map(\.entry.name)
        session.sort(by: .name, ascending: false)
        session.move([0], by: 1)
        #expect(session.move([0], to: 3) == [0])
        session.remove([0])
        session.nextStep()
        session.loadNames(fromText: "z")
        session.loadNames(from: memory.url("/f/a.txt"), completion: nil)
        session.editNames()
        session.clearGivenNames()
        session.start(completion: nil)
        session.undo(completion: nil)
        #expect(session.rows.map(\.entry.name) == before && session.givenNames.isEmpty && jobs.heldCount == 1)
        #expect(!interaction.log.contains { $0.hasPrefix("form:") })
        jobs.runHeld()
        #expect(!session.isBusy && names == ["xa.txt", "xb.txt", "xc.txt"])
    }

    // MARK: Cancelled runs

    /// A run cancelled at once renames nothing and keeps the list.
    @Test
    internal func aRunCancelledAtOnceRenamesNothing() {
        attachJobs(.atStart)
        let session = session()
        session.settings.nameMask = "x[N]"
        var result: RenameRunResult?
        session.start { result = $0 }
        #expect(result?.cancelled == true && names == ["a.txt", "b.txt", "c.txt"] && session.rowCount == 3)
    }

    /// A run cancelled while it asks about the conflicts renames nothing and says nothing.
    @Test
    internal func aRunCancelledWhileAskingAboutConflictsRenamesNothing() {
        attachJobs(.afterQuestion(1))
        let session = session()
        session.settings.nameMask = "same"
        interaction.choiceAnswers = [0]
        var result: RenameRunResult?
        session.start { result = $0 }
        #expect(result?.cancelled == true && names == ["a.txt", "b.txt", "c.txt"])
        #expect(!interaction.log.contains { $0.hasPrefix("inform:") })
    }

    /// An Undo cancelled before anything was put back keeps the run, so it can be undone later.
    @Test
    internal func anUndoCancelledAtOnceKeepsTheRun() {
        let session = session()
        session.settings.nameMask = "x[N]"
        session.start(completion: nil)
        attachJobs(.atStart)
        interaction.choiceAnswers = [0]
        var attempted: [RenamedItem] = []
        session.undo { attempted = $0 }
        #expect(names == ["xa.txt", "xb.txt", "xc.txt"] && attempted.count == 3)
        #expect(session.canUndo && session.store.lastUndo.count == 3)
        #expect(!interaction.log.contains { $0.hasPrefix("inform:") })
        // Asked again, it puts the files back.
        attachJobs(.never)
        interaction.choiceAnswers = [0]
        session.undo(completion: nil)
        #expect(names == ["a.txt", "b.txt", "c.txt"] && !session.canUndo)
    }

    // MARK: Long lists in the background

    /// "Next step" of a long list is made in the background.
    @Test
    internal func nextStepOfALongListIsMadeInTheBackground() async {
        let session = session(many(2_000), inBackground: true)
        session.settings.nameMask = "g[C]"
        #expect(await RunLoopWait.until { !session.isComputing })
        session.nextStep()
        #expect(await RunLoopWait.until { session.row(at: 0).entry.name == "g1.txt" && !session.isComputing })
        #expect(session.settings == .unchanged && session.row(at: 1_999).entry.name == "g2000.txt")
    }

    /// A "next step" overtaken by a change of the list is dropped.
    @Test
    internal func aNextStepOvertakenByAChangeOfTheListIsDropped() async {
        let session = session(many(2_000), inBackground: true)
        session.settings.nameMask = "g[C]"
        #expect(await RunLoopWait.until { !session.isComputing })
        session.nextStep()
        // The list changes before the step is back: the step was made for the old list.
        session.loadNames(fromText: "first")
        #expect(await RunLoopWait.until { !session.isComputing })
        #expect(session.row(at: 0).entry.name == "f0.txt" && session.givenNames == ["first"])
    }

    /// The text of the names of a long list is made in the background before it is shown.
    @Test
    internal func theNamesOfALongListAreEditedFromTheBackground() async {
        let session = session(many(2_000), inBackground: true)
        // No name for any of them: the text holds the old names.
        session.settings.nameMask = "[X]"
        #expect(await RunLoopWait.until { !session.isComputing && session.row(at: 0).newName == nil })
        interaction.formAnswers = [.values(["names": .text("one\ntwo")])]
        session.editNames()
        #expect(await RunLoopWait.until { session.givenNames == ["one", "two"] })
        #expect(interaction.log.contains("form: Edit names"))
    }

    /// The text of the first edit was made for the list before a change: only the second edit,
    /// made for the list as it is, is shown.
    @Test
    internal func anEditOfALongListThatIsOvertakenIsDropped() async {
        let session = session(many(2_000), inBackground: true)
        session.editNames()
        session.clearGivenNames()
        interaction.formAnswers = [.values(["names": .text("second")])]
        session.editNames()
        #expect(await RunLoopWait.until { session.givenNames == ["second"] })
        #expect(interaction.log.filter { $0 == "form: Edit names" }.count == 1)
    }

    /// Names are loaded from a file in the background.
    @Test
    internal func namesAreLoadedFromAFileInTheBackground() async {
        memory.addFile("/lists/names.txt", "one\ntwo\nthree")
        let session = session(inBackground: true)
        var loaded = false
        session.loadNames(from: memory.url("/lists/names.txt")) { loaded = true }
        #expect(await RunLoopWait.until { loaded })
        #expect(session.givenNames == ["one", "two", "three"])
    }

    /// An empty list of names gives the masks back.
    @Test
    internal func anEmptyListOfNamesGivesTheMasksBack() {
        let session = session()
        session.loadNames(fromText: "x")
        #expect(session.givenNames == ["x"])
        session.loadNames(fromText: "\n\n")
        #expect(session.givenNames.isEmpty)
    }

    /// An Undo with the work in the background decodes the runs first, then puts the files back.
    @Test
    internal func anUndoInTheBackgroundDecodesTheRunsFirst() async {
        let session = session(inBackground: true)
        session.settings.nameMask = "x[N]"
        session.start(completion: nil)
        #expect(names == ["xa.txt", "xb.txt", "xc.txt"])
        interaction.choiceAnswers = [0]
        var isUndone = false
        session.undo { _ in isUndone = true }
        #expect(await RunLoopWait.until { isUndone })
        #expect(names == ["a.txt", "b.txt", "c.txt"])
    }
}
