import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// What the lists of a panel do for the keyboard and the standard editing actions: Cut, Copy and
/// Paste through the responder chain, keys bound to commands, Page Up and Down in the grid, and
/// Space on `[..]`.
@MainActor
@Suite(.serialized)
internal struct PanelKeysTests {
    private let program: PanelProgram

    /// The program's folders: `A` with `docs`, `one.txt`, `two.txt`; `B` with `fresh.txt`.
    internal init() throws {
        program = try PanelProgram(rightFile: "fresh.txt", contents: "fresh")
    }

    /// Starts the program with the plugins a file manager cannot do without.
    private func start() async -> PanelProgram.Running {
        let app = await program.start(
            plugins: CorePlugins.make(pasteboard: program.scratch.pasteboard),
            fileSystems: []
        )
        app.layOut()
        return app
    }

    /// Cut, Copy and Paste reach the panel's commands of their role and can be chosen while those
    /// can run; menu entries of other actions can always be chosen.
    @Test
    internal func cutCopyAndPasteRunThePanelsCommands() async {
        let app = await start()
        defer { app.stop() }
        app.cursor(app.left, on: "one.txt")
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        #expect(app.left.validateUserInterfaceItem(copy))
        #expect(app.left.validateUserInterfaceItem(NSMenuItem(title: "Other", action: nil, keyEquivalent: "")))
        app.left.copy(nil)
        #expect(PanelDrop.locations(on: program.scratch.pasteboard).map(\.lastPathComponent) == ["one.txt"])
        // The commands work in the source panel: the right one cuts, the left one pastes.
        app.right.focus()
        app.cursor(app.right, on: "fresh.txt")
        app.right.cut(nil)
        app.left.focus()
        app.left.paste(nil)
        #expect(
            await PanelWait.until {
                !app.kernel.jobs.isBusy && FileManager.default.fileExists(atPath: program.box.url("A/fresh.txt").path)
            }
        )
        #expect(!FileManager.default.fileExists(atPath: program.box.url("B/fresh.txt").path))
    }

    /// A panel without the commands of those roles (no clipboard plugin) offers none of them.
    @Test
    internal func withoutAClipboardTheEditingActionsCannotBeChosen() {
        let kernel = Kernel(productName: "Test", settings: MemorySettings(), interaction: ScriptedInteraction())
        let panel = PanelViewController(tabs: PanelTabs(PanelModel(directory: program.box.url("A"))), kernel: kernel)
        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        #expect(!panel.validateUserInterfaceItem(paste))
        panel.paste(nil)
        #expect(panel.model.items.isEmpty)
    }

    /// A key bound to a command runs it from the list; Page Down in the grid goes a page of
    /// cells; Space on `[..]` marks nothing; a double click on no row of the table opens nothing.
    @Test
    internal func boundKeysPagesSpaceAndDoubleClicks() async {
        let app = await start()
        defer { app.stop() }
        #expect(app.left.handleListKey(PanelProgram.key(0, "a", .command), arrowsMoveCursor: false))
        #expect(app.left.model.selection == ["docs", "one.txt", "two.txt"])
        app.commands.perform(.unselectAll, .nothing)
        app.left.model.moveCursor(to: 0)
        app.left.toggleSelectionWithSize()
        #expect(app.left.model.selection.isEmpty && app.left.sizeCalculations.isEmpty)
        app.left.rowDoubleClicked()
        #expect(app.left.model.directory.lastPathComponent == "A")
        app.commands.perform(.viewBrief, .nothing)
        app.layOut()
        #expect(app.left.pageSize == app.left.gridView.geometry.pageSize)
    }

    /// The size of a folder that is marked with Space is dropped when the panel has moved on before
    /// it came.
    @Test
    internal func aFolderSizeThatComesAfterThePanelMovedOnIsDropped() async {
        let app = await start()
        defer { app.stop() }
        app.cursor(app.left, on: "docs")
        let tab = app.left.model
        app.left.toggleSelectionWithSize()
        app.left.show(program.box.url("B"))
        await program.settle(app)
        await PanelWait.drainMainQueue()
        #expect(tab.directory.lastPathComponent == "B" && tab.items.allSatisfy { $0.computedSize == nil })
    }
}
