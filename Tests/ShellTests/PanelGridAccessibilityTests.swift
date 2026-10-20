import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The grid of the Brief and Thumbnails views to the accessibility interface: a list whose
/// children are the cells on screen, named as the list writes them, the cursor's selected.
@MainActor
@Suite(.serialized)
internal struct PanelGridAccessibilityTests {
    private let program: PanelProgram

    /// The program's folders: `A` with `docs`, `one.txt`, `two.txt`.
    internal init() throws {
        program = try PanelProgram(rightFile: "fresh.txt", contents: "fresh")
    }

    /// The elements the grid offers now.
    private static func cells(of grid: FileGridView) -> [NSAccessibilityElement] {
        (grid.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
    }

    /// The left panel shows the Brief view, drawn once.
    private func startInBrief() async -> PanelProgram.Running {
        let app = await program.start(
            plugins: CorePlugins.make(pasteboard: program.scratch.pasteboard),
            fileSystems: []
        )
        app.commands.perform(.viewBrief, .nothing)
        app.layOut()
        PanelDropHelpers.draw(app.left.gridView)
        return app
    }

    /// The list is one element with a cell for each entry on screen, where the entry is drawn;
    /// the cursor's cell is the selected one.
    @Test
    internal func theCellsOnScreenAreTheChildrenOfTheList() async throws {
        let app = await startInBrief()
        defer { app.stop() }
        let grid = app.left.gridView
        #expect(grid.isAccessibilityElement() && grid.accessibilityRole() == .list)
        #expect(grid.accessibilityLabel() == "File list")
        let cells = Self.cells(of: grid)
        let model = app.left.model
        #expect(
            cells.map { $0.accessibilityLabel() }
                == (0..<model.rowCount)
                .map { row in
                    GridCellPainter.caption(for: model.item(atRow: row))
                }
        )
        #expect(cells.first?.accessibilityLabel() == "[..]" && cells.contains { $0.accessibilityLabel() == "one.txt" })
        #expect(cells.allSatisfy { $0.accessibilityRole() == .cell && $0.accessibilityParent() as? NSView === grid })
        let window = try #require(grid.window)
        let second = window.convertToScreen(grid.convert(grid.geometry.frame(of: 1), to: nil))
        #expect(cells[1].accessibilityFrame() == second)
        #expect(cells.map { $0.isAccessibilitySelected() } == (0..<cells.count).map { $0 == model.cursor })
        #expect((grid.accessibilitySelectedChildren() as? [NSAccessibilityElement]) == [cells[model.cursor]])
    }

    /// A point of the screen over a cell finds that cell; empty space, and a list in no window,
    /// find the list.
    @Test
    internal func aPointFindsTheCellUnderIt() async throws {
        let app = await startInBrief()
        defer { app.stop() }
        let grid = app.left.gridView
        let window = try #require(grid.window)
        let cells = Self.cells(of: grid)
        let middle = NSPoint(x: grid.geometry.frame(of: 1).midX, y: grid.geometry.frame(of: 1).midY)
        let onScreen = window.convertPoint(toScreen: grid.convert(middle, to: nil))
        #expect(grid.accessibilityHitTest(onScreen) as? NSAccessibilityElement === cells[1])
        let empty = window.convertPoint(toScreen: grid.convert(NSPoint(x: -5, y: -5), to: nil))
        #expect(grid.accessibilityHitTest(empty) as? FileGridView === grid)
        let alone = FileGridView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        #expect(alone.accessibilityHitTest(.zero) as? FileGridView === alone)
    }

    /// Drawn again without a change, the list keeps its elements; a cursor that moved, or a
    /// list taken from the model again, makes them again.
    @Test
    internal func theElementsAreMadeAgainOnlyWhenWhatTheyShowChanged() async throws {
        let app = await startInBrief()
        defer { app.stop() }
        let grid = app.left.gridView
        let before = Self.cells(of: grid)
        PanelDropHelpers.draw(grid)
        #expect(Self.cells(of: grid).first === before.first)

        app.cursor(app.left, on: "two.txt")
        PanelDropHelpers.draw(grid)
        let moved = Self.cells(of: grid)
        let row = try #require(app.left.model.row(ofName: "two.txt"))
        #expect(moved.first !== before.first && moved[row].isAccessibilitySelected())

        grid.reload(flow: .columns)
        PanelDropHelpers.draw(grid)
        #expect(Self.cells(of: grid).first !== moved.first)
    }
}
