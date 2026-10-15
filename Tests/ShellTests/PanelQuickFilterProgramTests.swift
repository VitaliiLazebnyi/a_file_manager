import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The quick filter through the real program (spec 03 › Quick filter): narrowing the list
/// while typing, over the display filter, per tab and per folder.
@MainActor
@Suite(.serialized)
internal struct PanelQuickFilterProgramTests {
    private let program: PanelProgram

    /// The program's folders, with `B/fresh.txt`.
    internal init() throws {
        program = try PanelProgram(rightFile: "fresh.txt", contents: "fresh")
    }

    /// Starts the program with the plugins a file manager cannot do without.
    private func start() async -> PanelProgram.Running {
        await program.start(plugins: CorePlugins.make(pasteboard: program.scratch.pasteboard), fileSystems: [])
    }

    /// The list narrows as text is typed; Enter goes back to the list and keeps the filter, a
    /// reading of the folder keeps it, Esc takes it away, and an empty field goes by itself.
    @Test
    internal func theQuickFilterNarrowsTheListWhileTyping() async {
        let app = await start()
        defer { app.stop() }
        #expect(
            app.left.quickFilterBar.isHidden
                && app.kernel.keyBindings.command(for: Shortcut(.character("s"), .control)) == .quickFilter
        )
        app.commands.perform(.quickFilter, .nothing)
        #expect(
            !app.left.quickFilterBar.isHidden && app.left.quickFilterText?.isEmpty == true
                && app.right.quickFilterBar.isHidden
        )
        app.left.quickFilterTyped("t")
        #expect(app.names(app.left) == ["one.txt", "two.txt"] && app.left.tableView.numberOfRows == 3)
        app.left.quickFilterTyped("tw")
        #expect(
            app.names(app.left) == ["two.txt"] && app.left.statusLineText == "0 k / 0 k in 0 / 1 file(s)   ⏷ Filter: tw"
        )
        app.left.quickFilterTyped("*o*")
        #expect(app.names(app.left) == ["docs", "one.txt", "two.txt"])
        app.left.quickFilterTyped("O?E*")
        #expect(app.names(app.left) == ["one.txt"])
        // Enter goes back to the list and keeps filter and field; the path bar still shows the display mask.
        app.left.leaveQuickFilterField()
        #expect(
            !app.left.quickFilterBar.isHidden && app.names(app.left) == ["one.txt"]
                && app.left.pathBarText.hasSuffix("/A/*.*")
        )
        // A reading of the folder keeps the filter.
        app.commands.perform(.reread, .nothing)
        await program.settle(app)
        #expect(app.names(app.left) == ["one.txt"] && app.left.quickFilterText == "O?E*")
        // Esc in the list takes it away.
        #expect(program.press(app, 53, []) && app.left.quickFilterBar.isHidden && app.names(app.left).count == 3)
        #expect(
            app.left.quickFilterText == nil && !app.left.statusLineText.contains("Filter")
                && !program.press(app, 53, [])
        )
        // A field that was left empty goes away by itself.
        app.commands.perform(.quickFilter, .nothing)
        app.left.leaveQuickFilterField()
        #expect(app.left.quickFilterBar.isHidden)
    }

    /// The filter ends with its folder, lies over the display filter and gives it back, goes
    /// with All Files, and belongs to its tab.
    @Test
    internal func theQuickFilterEndsWithTheFolderAndLiesOverTheDisplayFilter() async {
        let app = await start()
        defer { app.stop() }
        // Going into a folder: the filter does not hide where the cursor should go.
        app.commands.perform(.changeDirectory, .location(program.box.url("A/docs")))
        await program.settle(app)
        app.commands.perform(.quickFilter, .nothing)
        app.left.quickFilterTyped("zzz")
        #expect(app.names(app.left).isEmpty)
        app.commands.perform(.goToParent, .nothing)
        await program.settle(app)
        #expect(app.left.model.directory.lastPathComponent == "A" && app.left.model.cursorItem?.name == "docs")
        #expect(app.left.model.filter == nil && app.left.quickFilterBar.isHidden && app.names(app.left).count == 3)
        // Over a display filter: both count, and the display filter comes back.
        app.commands.perform("cm_SrcUserDef", .text("*.txt | docs/"))
        #expect(app.names(app.left) == ["one.txt", "two.txt"] && app.left.pathBarText.hasSuffix("/A/*.txt | docs/"))
        app.commands.perform(.quickFilter, .nothing)
        app.left.quickFilterTyped("o")
        app.left.quickFilterTyped("on")
        #expect(app.names(app.left) == ["one.txt"] && app.commands.isChecked("cm_SrcUserDef"))
        #expect(app.left.pathBarText.hasSuffix("/A/*.txt | docs/"))
        app.left.removeQuickFilter()
        #expect(app.names(app.left) == ["one.txt", "two.txt"] && app.left.model.filter?.title == "*.txt | docs/")
        // All Files removes a quick filter as well.
        app.commands.perform(.quickFilter, .nothing)
        app.left.quickFilterTyped("tw")
        app.commands.perform("cm_SrcAllFiles", .nothing)
        #expect(app.names(app.left).count == 3 && app.left.quickFilterBar.isHidden && app.left.quickFilterText == nil)
        #expect(app.left.pathBarText.hasSuffix("/A/*.*"))
        // Each tab has its own; the new tab is a copy, but the quick filter stays with the old tab.
        app.commands.perform(.quickFilter, .nothing)
        app.left.quickFilterTyped("one")
        app.commands.perform(.newTab, .nothing)
        await program.settle(app)
        #expect(app.left.quickFilterBar.isHidden && app.left.quickFilterText == nil)
        #expect(app.left.model.filter == nil && app.names(app.left).count == 3 && !program.press(app, 53, []))
        app.commands.perform(.previousTab, .nothing)
        await program.settle(app)
        #expect(
            !app.left.quickFilterBar.isHidden && app.left.quickFilterBar.text == "one"
                && app.names(app.left) == ["one.txt"]
        )
    }

    /// Typing waits for the last key of a burst; Enter filters at once; Esc before the list
    /// followed leaves it as it was; the field's own keys do the same.
    @Test
    internal func typingInTheQuickFilterWaitsForTheLastKeyAndEnterDoesNotWaitAtAll() async {
        let app = await start()
        defer { app.stop() }
        app.commands.perform(.quickFilter, .nothing)
        app.left.quickFilterBar.text = "t"
        app.left.quickFilterEdited("t")
        app.left.quickFilterBar.text = "tw"
        app.left.quickFilterEdited("tw")
        // Not filtered key by key: the list follows in a moment, once.
        #expect(app.names(app.left).count == 3)
        #expect(await PanelWait.until { app.names(app.left) == ["two.txt"] })
        #expect(app.left.quickFilterText == "tw")
        // Enter filters with what is typed, at once.
        app.left.quickFilterBar.text = "one"
        app.left.quickFilterEdited("one")
        app.left.leaveQuickFilterField()
        #expect(app.names(app.left) == ["one.txt"] && app.left.quickFilterText == "one")
        // Esc before the list followed leaves it as it was.
        app.left.quickFilterBar.text = "zzz"
        app.left.quickFilterEdited("zzz")
        app.left.removeQuickFilter()
        await PanelWait.pause(PanelViewController.quickFilterDelay * 3)
        #expect(app.names(app.left).count == 3 && app.left.quickFilterText == nil)
        // The field's keys: typing, Enter and Esc reach the panel through the bar.
        app.commands.perform(.quickFilter, .nothing)
        let bar = app.left.quickFilterBar
        bar.text = "two"
        bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(bar.control(bar.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(app.names(app.left) == ["two.txt"])
        #expect(!bar.control(bar.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveLeft(_:))))
        #expect(bar.control(bar.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(app.left.quickFilterBar.isHidden && app.names(app.left).count == 3)
        app.commands.perform(.quickFilter, .nothing)
        bar.closeButton.performClick(nil)
        #expect(bar.isHidden)
    }

    /// Clicks that mark are refused while a job runs; a plain click is left to the list.
    @Test
    internal func clicksThatMarkAreRefusedWhileAJobRunsButAPlainClickIsLeftToTheList() async throws {
        let app = await start()
        defer { app.stop() }
        app.commands.isBlocked = { true }
        #expect(!app.left.handleClick(row: 2, modifiers: []))
        #expect(app.left.handleClick(row: 2, modifiers: .command) && app.left.model.selection.isEmpty)
        #expect(app.left.handleClick(row: 2, modifiers: .shift) && app.left.model.selection.isEmpty)
        app.commands.isBlocked = { false }
        #expect(app.left.handleClick(row: 2, modifiers: .command))
        #expect(app.left.model.selection == [try #require(app.left.model.item(atRow: 2)).name])
    }
}
