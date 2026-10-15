import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// Drags and drops in the grid of the Brief view of a real program (spec 05 › Drag & drop).
@MainActor
@Suite(.serialized)
internal struct PanelGridDropTests {
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

    /// The grid takes a drag the same way: it frames the row a drop would go into (the list as a
    /// whole for the panel's folder), forgets it when the drag leaves or ends, and carries out a
    /// drop.
    @Test
    internal func theGridJudgesADragAndCarriesOutTheDrop() async {
        let app = await start()
        defer {
            app.stop()
            PanelDrop.endSession(nil)
        }
        app.left.settings.confirmsDrops = false
        app.commands.perform(.viewBrief, .nothing)
        app.layOut()
        let grid = app.left.gridView
        let board = PanelDropHelpers.pasteboard([program.box.url("B/fresh.txt")])
        defer { board.releaseGlobally() }
        let info = PanelDraggingInfo(
            sequence: 7_101,
            pasteboard: board,
            location: PanelDropHelpers.point(ofRow: 1, in: grid),
            allowed: PanelDraggingInfo.anything
        )
        #expect(grid.draggingEntered(info) == .move && grid.dropRow == 1)
        grid.display()
        info.draggingLocation = PanelDropHelpers.point(ofRow: 2, in: grid)
        #expect(grid.draggingUpdated(info) == .move && grid.dropRow == -1)
        grid.display()
        // (A drag of this program that another test left under way would keep the session.)
        PanelDrop.endDrag()
        grid.draggingExited(info)
        #expect(grid.dropRow == nil && PanelDrop.session == nil)
        let own = PanelDropHelpers.pasteboard([program.box.url("A/one.txt")])
        defer { own.releaseGlobally() }
        let refused = PanelDraggingInfo(
            sequence: 7_102,
            pasteboard: own,
            location: PanelDropHelpers.point(ofRow: 2, in: grid),
            allowed: PanelDraggingInfo.anything
        )
        #expect(grid.draggingUpdated(refused).isEmpty && grid.dropRow == nil)
        grid.draggingEnded(refused)
        #expect(PanelDrop.session == nil)
        info.draggingLocation = PanelDropHelpers.point(ofRow: 1, in: grid)
        #expect(grid.performDragOperation(info) && grid.dropRow == nil)
        #expect(await PanelWait.until { exists("A/docs/fresh.txt") && !app.kernel.jobs.isBusy })
    }

    /// A press on a cell of the grid that moves starts a drag of that cell's item; the drag's
    /// pasteboard names it; a press that hardly moves starts nothing.
    @Test
    internal func aPressThatMovesStartsADragInTheGrid() async throws {
        let app = await start()
        defer {
            app.stop()
            PanelDrop.endDrag()
            PanelDrop.endSession(nil)
        }
        app.commands.perform(.viewBrief, .nothing)
        app.layOut()
        let grid = app.left.gridView
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var dragged: [Int] = []
        grid.beginsDraggingSession = { _, items, _ in
            dragged.append(items.count)
            return PanelDragSession(board)
        }
        let window = try #require(grid.window)
        func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type,
                    location: point,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )
            )
        }
        let start = PanelDropHelpers.point(ofRow: 2, in: grid)
        grid.mouseDown(with: try event(.leftMouseDown, start))
        grid.mouseDragged(with: try event(.leftMouseDragged, NSPoint(x: start.x + 2, y: start.y)))
        #expect(PanelDrop.current == nil)
        grid.mouseDragged(with: try event(.leftMouseDragged, NSPoint(x: start.x + 30, y: start.y)))
        #expect(PanelDrop.current?.items.map(\.name) == ["one.txt"] && dragged == [1])
        let session = PanelDragSession(board)
        #expect(grid.draggingSession(session, sourceOperationMaskFor: .outsideApplication) == [.copy, .move, .generic])
        grid.draggingSession(session, endedAt: .zero, operation: .copy)
        #expect(PanelDrop.current == nil)
        // `[..]` drags nothing.
        grid.mouseDown(with: try event(.leftMouseDown, PanelDropHelpers.point(ofRow: 0, in: grid)))
        grid.mouseDragged(with: try event(.leftMouseDragged, PanelDropHelpers.point(ofRow: 2, in: grid)))
        #expect(PanelDrop.current == nil && dragged == [1])
    }

    /// A drag of many marked items in the grid carries them all; only the first few are dragged
    /// with a picture.
    @Test
    internal func aDragOfManyMarkedItemsInTheGridCarriesThemAll() async throws {
        for index in 0..<12 {
            try program.box.file(String(format: "A/many/f%02d.txt", index))
        }
        let app = await start()
        defer {
            app.stop()
            PanelDrop.endDrag()
        }
        app.left.show(program.box.url("A/many"))
        await program.settle(app)
        app.commands.perform(.viewBrief, .nothing)
        app.layOut()
        app.left.model.selectAll()
        let grid = app.left.gridView
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var dragged: [Int] = []
        grid.beginsDraggingSession = { _, items, _ in
            dragged.append(items.count)
            return PanelDragSession(board)
        }
        let window = try #require(grid.window)
        let press = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDragged,
                location: PanelDropHelpers.point(ofRow: 3, in: grid),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
        grid.startDrag(ofRow: 3, for: app.left, with: press)
        // One pasteboard item per file up to the number written singly, each a dragged item.
        #expect(PanelDrop.current?.itemCount == 12 && dragged == [12] && FileGridView.imagedDragItems < 12)
    }
}
