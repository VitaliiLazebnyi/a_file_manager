import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// Drops through the views of a real program (spec 05 › Drag & drop): what the table and the
/// grid tell AppKit while something is dragged over them, and what a drop does.
@MainActor
@Suite(.serialized)
internal struct PanelDropTests {
    private let program: PanelProgram

    /// The program's folders: `A` with `docs`, `one.txt`, `two.txt`; `B` with `fresh.txt`.
    internal init() throws {
        program = try PanelProgram(rightFile: "fresh.txt", contents: "fresh")
    }

    /// Starts the program with the plugins a file manager cannot do without, laid out.
    private func start() async -> PanelProgram.Running {
        let app = await program.start(
            plugins: CorePlugins.make(pasteboard: program.scratch.pasteboard),
            fileSystems: []
        )
        app.layOut()
        return app
    }

    /// Whether `path` of the sandbox exists.
    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: program.box.url(path).path)
    }

    /// A file of another program dragged over a folder row of the table is moved there when
    /// dropped (same volume); over the panel's own folder its own file is refused; a source that
    /// allows only a generic drag gets one.
    @Test
    internal func theTableJudgesADragAndCarriesOutTheDrop() async {
        let app = await start()
        defer {
            app.stop()
            PanelDrop.endSession(nil)
        }
        app.left.settings.confirmsDrops = false
        let table = app.left.tableView
        let board = PanelDropHelpers.pasteboard([program.box.url("B/fresh.txt")])
        defer { board.releaseGlobally() }
        let info = PanelDraggingInfo(
            sequence: 7_001,
            pasteboard: board,
            location: PanelDropHelpers.point(ofRow: 1, in: table),
            allowed: PanelDraggingInfo.anything
        )
        #expect(app.left.tableView(table, validateDrop: info, proposedRow: 1, proposedDropOperation: .on) == .move)
        let generic = PanelDraggingInfo(
            sequence: 7_002,
            pasteboard: board,
            location: PanelDropHelpers.point(ofRow: 1, in: table),
            allowed: .generic
        )
        #expect(app.left.validateDrop(generic, row: 1) == (.generic, 1))
        let own = PanelDropHelpers.pasteboard([program.box.url("A/one.txt")])
        defer { own.releaseGlobally() }
        let refused = PanelDraggingInfo(
            sequence: 7_003,
            pasteboard: own,
            location: PanelDropHelpers.point(ofRow: 2, in: table),
            allowed: PanelDraggingInfo.anything
        )
        #expect(app.left.tableView(table, validateDrop: refused, proposedRow: 2, proposedDropOperation: .on).isEmpty)
        #expect(!app.left.tableView(table, acceptDrop: refused, row: 2, dropOperation: .on))
        // The drop: the file goes into `docs`, after the drag has ended.
        #expect(app.left.tableView(table, acceptDrop: info, row: 1, dropOperation: .on))
        #expect(await PanelWait.until { exists("A/docs/fresh.txt") && !app.kernel.jobs.isBusy })
        #expect(!exists("B/fresh.txt"))
    }

    /// A drop is asked about first when the user wants that: Cancel leaves everything as it was,
    /// Copy copies; while a job runs, a drop is turned away.
    @Test
    internal func aDropIsAskedAboutFirstAndTurnedAwayWhileAJobRuns() async {
        let app = await start()
        defer { app.stop() }
        let plan = PanelDropPlan(
            kind: .copy,
            sources: [program.box.url("B/fresh.txt")],
            destination: program.box.url("A"),
            row: -1
        )
        program.interaction.choiceAnswers = [1, 0]
        app.left.carryOut(plan)
        #expect(!exists("A/fresh.txt") && program.interaction.log.contains { $0.hasPrefix("choose: Copy 1 item to") })
        app.left.carryOut(plan)
        #expect(await PanelWait.until { exists("A/fresh.txt") && !app.kernel.jobs.isBusy })
        // While a job runs.
        let gate = DispatchSemaphore(value: 0)
        app.kernel.jobs.run(
            title: "Busy",
            work: { _ in gate.wait() },
            completion: { _ in
                // Only that a job runs counts here.
            }
        )
        defer { gate.signal() }
        let moved = PanelDropPlan(kind: .move, sources: plan.sources, destination: program.box.url("A/docs"), row: 1)
        app.left.carryOut(moved)
        #expect(exists("B/fresh.txt") && !exists("A/docs/fresh.txt"))
    }

    /// The table's own drags: the grabbed row goes on the pasteboard, the marked items join it
    /// when the drag begins, and the end of the drag forgets them.
    @Test
    internal func theTablesDragsCarryTheMarkedItems() async {
        let app = await start()
        defer {
            app.stop()
            PanelDrop.endDrag()
        }
        let table = app.left.tableView
        app.left.model.setSelected(true, rows: 2...3)
        #expect(app.left.tableView(table, pasteboardWriterForRow: 2) != nil && app.left.pendingDragItems.count == 2)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        let session = PanelDragSession(board)
        app.left.tableView(table, draggingSession: session, willBeginAt: .zero, forRowIndexes: [2])
        #expect(app.left.pendingDragItems.isEmpty && PanelDrop.locations(on: board).count == 2)
        #expect(app.left.tableView(table, pasteboardWriterForRow: 0) == nil)
        app.left.tableView(table, draggingSession: session, willBeginAt: .zero, forRowIndexes: [0])
        app.left.tableView(table, draggingSession: session, endedAt: .zero, operation: .copy)
        #expect(PanelDrop.current == nil && PanelDrop.session == nil && app.left.pendingDragItems.isEmpty)
    }

    /// The program's own drag of files of another file system is a copy wherever it is dropped,
    /// and is read once per drag; a pasteboard that is gone names nothing.
    @Test
    internal func theProgramsOwnDragFromAnotherFileSystemIsACopy() async throws {
        program.memory.addFile("/M/remote.txt", "far")
        let app = await start()
        defer {
            app.stop()
            PanelDrop.endDrag()
            PanelDrop.endSession(nil)
        }
        app.right.show(program.memory.url("/M"))
        await program.settle(app)
        let payload = try #require(app.right.dragPayload(fromRow: 1))
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        board.writeObjects(PanelDrop.beginDrag(payload))
        let info = PanelDraggingInfo(
            sequence: 7_201,
            pasteboard: board,
            location: PanelDropHelpers.point(ofRow: 1, in: app.left.tableView),
            allowed: PanelDraggingInfo.anything
        )
        #expect(app.left.validateDrop(info, row: 1) == (.copy, 1))
        let session = PanelDrop.session(for: info)
        #expect(PanelDrop.session(for: info) === session)
        #expect(PanelDrop.session(for: info).sources.map(\.path) == ["/M/remote.txt"])
        board.releaseGlobally()
        PanelDrop.endDrag()
        #expect(PanelDrop.locations(on: board).isEmpty)
    }
}
