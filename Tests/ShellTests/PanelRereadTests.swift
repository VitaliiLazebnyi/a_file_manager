import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// Reading a tab's folder again, in the cases the program does not meet every day: nothing can be
/// read at all, the folder is gone, a rename or a job is in the way, the reading is overtaken, and
/// the window goes away while readings and questions are out.
@MainActor
@Suite(.serialized)
internal struct PanelRereadTests {
    private let program: PanelProgram

    /// The program's folders, with `/m/sub/z.txt` on the memory file system.
    internal init() throws {
        program = try PanelProgram(rightFile: "fresh.txt", contents: "fresh")
        program.memory.addFile("/m/sub/z.txt")
        program.memory.addFile("/m/y.txt")
    }

    /// Starts the program with the right panel in `/m/sub` of the memory file system.
    private func start() async -> PanelProgram.Running {
        let app = await program.start(
            plugins: CorePlugins.make(pasteboard: program.scratch.pasteboard),
            fileSystems: []
        )
        app.right.show(program.memory.url("/m/sub"))
        await program.settle(app)
        return app
    }

    /// A folder that cannot be read, nor anything above it, keeps what it showed; the user hears
    /// of it when asked for the reading, not when it was quiet.
    @Test
    internal func aFolderThatCannotBeReadAtAllKeepsWhatItShowed() async {
        let app = await start()
        defer { app.stop() }
        program.memory.unreadable = ["/", "/m", "/m/sub"]
        var done = 0
        app.right.reload(focus: nil, quietly: true) { done += 1 }
        #expect(await PanelWait.until { done == 1 })
        await PanelWait.drainMainQueue()
        #expect(program.interaction.log.isEmpty && app.names(app.right) == ["z.txt"])
        app.right.reload(focus: nil, quietly: false) { done += 1 }
        #expect(await PanelWait.until { done == 2 && !program.interaction.log.isEmpty })
        #expect(app.names(app.right) == ["z.txt"])
    }

    /// A folder that is gone is replaced by its parent: what was calculated and remembered for
    /// it goes.
    @Test
    internal func aFolderThatIsGoneIsReplacedByItsParent() async {
        let app = await start()
        defer { app.stop() }
        let size = CancellationFlag()
        app.right.sizeCalculations[ObjectIdentifier(app.right.model)] = size
        program.memory.removeTree("/m/sub")
        var done = false
        app.right.reload(focus: nil, quietly: false) { done = true }
        #expect(await PanelWait.until { done })
        #expect(app.right.model.directory.path == "/m" && size.isCancelled)
        #expect(app.kernel.listingCache.entry(for: program.memory.url("/m/sub"), showHidden: false) == nil)
    }

    /// A change noticed while a name is edited, or while a job runs, is read when that is over; a
    /// reading that would not be made up for tells whoever waits at once.
    @Test
    internal func aRenameOrAJobPutsTheReadingOff() async {
        let app = await start()
        defer { app.stop() }
        let panel = app.right
        let id = ObjectIdentifier(panel.model)
        app.cursor(panel, on: "z.txt")
        panel.beginRename()
        panel.dirty[id] = [panel.model.directory.locationKey]
        panel.rereadIfDirty()
        #expect(panel.loads.isEmpty && panel.dirty[id] != nil)
        var told = false
        panel.dirty[id] = nil
        panel.reload(panel.model, focus: nil, as: .quietOnce) { told = true }
        #expect(told)
        if let field = panel.renameField {
            _ = panel.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        }
        let gate = DispatchSemaphore(value: 0)
        app.kernel.jobs.run(
            title: "Busy",
            work: { _ in gate.wait() },
            completion: { _ in
                // Only that a job runs counts here.
            }
        )
        panel.dirty[id] = [panel.model.directory.locationKey]
        panel.rereadIfDirty()
        #expect(panel.loads.isEmpty)
        gate.signal()
        #expect(await PanelWait.until { !app.kernel.jobs.isBusy })
    }

    /// A reading again that is overtaken before its turn asks the file system nothing.
    @Test
    internal func anOvertakenReadingAgainAsksNothing() async {
        let app = await start()
        defer { app.stop() }
        let asked = program.memory.listRequests(for: "/m/sub")
        let gate = DispatchSemaphore(value: 0)
        Background.storage("list", at: program.memory.url("/m/sub")) { gate.wait() }
        app.right.reload(focus: nil, quietly: false, completion: nil)
        app.right.show(program.memory.url("/m"))
        gate.signal()
        await program.settle(app)
        #expect(app.right.model.directory.path == "/m" && program.memory.listRequests(for: "/m/sub") == asked)
    }

    /// When the window goes, the questions about volumes are given up and whoever waits for a
    /// reading hears that it came to nothing.
    @Test
    internal func theWindowGoingGivesUpWhatIsOut() async {
        let app = await start()
        defer { app.stop() }
        let id = ObjectIdentifier(app.right.model)
        let question = CancellationFlag()
        var told = false
        app.right.volumeAsking[id] = question
        app.right.waitingCompletions[id] = [{ told = true }]
        app.right.cancelLoading()
        #expect(question.isCancelled && told && app.right.volumeAsking.isEmpty)
    }
}
