import AFMContracts
import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// The *Choose command* dialog, driven as the user would, with nothing put on screen.
@MainActor
@Suite
internal struct CovConfigBrowser {
    private let stage: CovConfigStage
    private let windows = StabilityWindows { $0.title == "Choose Command" }
    private let browser: CommandBrowserController
    /// The commands a test can run.
    private let ran: CovConfigProbes

    private var content: NSView? { browser.window?.contentView }
    private var list: RowsTable? { CovConfigStage.views(RowsTable.self, in: content).first }
    private var filter: NSSearchField? { CovConfigStage.views(NSSearchField.self, in: content).first }
    private var categories: NSPopUpButton? { CovConfigStage.views(NSPopUpButton.self, in: content).first }

    /// A fresh stage for every test.
    internal init() throws {
        stage = try CovConfigStage()
        ran = CovConfigProbes(["cov_alpha", "cov_beta"], in: stage.commands)
        stage.center.save(UserCommand(name: "em_mine", title: "Mine", action: CommandAction(command: "cov_alpha")))
        browser = stage.center.browser()
    }

    /// The position of a command in the list.
    private func row(_ name: String) -> Int? {
        browser.rows.firstIndex { $0.id.rawValue == name }
    }

    private func press(_ title: String) {
        #expect(CovConfigStage.press(title, in: content), "\(title)")
    }

    /// Filters the list as typing does.
    private func type(_ text: String) {
        filter?.stringValue = text
        browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }

    private func key(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: browser.window?.windowNumber ?? 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        )
    }

    private func finish() {
        stage.close()
        #expect(windows.shown.isEmpty && windows.open.isEmpty)
        windows.closeAll()
    }

    /// Opened on its own the dialog runs the chosen command and closes; with nothing chosen it beeps.
    @Test
    internal func onItsOwnItRunsTheChosenCommand() {
        defer { finish() }
        browser.show(category: nil)
        #expect(stage.presented.last === browser)
        type("cov_beta")
        #expect(browser.rows.map(\.id) == ["cov_beta"])
        press("Run")
        #expect(ran.names == ["cov_beta"])
        type("nothing is called like this")
        #expect(returnInFilter())
        #expect(stage.beeps == 1)
        press("Cancel")
    }

    /// Return in the filter as its field editor tells the delegate.
    private func returnInFilter(_ selector: Selector = #selector(NSResponder.insertNewline(_:))) -> Bool {
        browser.control(filter ?? NSSearchField(), textView: NSTextView(), doCommandBy: selector)
    }

    /// Typing a filter only narrows the list: the field sends no action (a search field sends
    /// its action while the user types, and that ran the first command of the half-narrowed
    /// list); Return runs the selected command, other keys stay the field's.
    @Test
    internal func typingAFilterRunsNothingUntilReturn() throws {
        defer { finish() }
        browser.show(category: nil)
        let field = try #require(filter)
        #expect(field.action == nil && field.target == nil)
        type("cov_")
        #expect(browser.rows.map(\.id) == ["cov_alpha", "cov_beta"] && ran.names.isEmpty)
        #expect(!returnInFilter(#selector(NSResponder.moveDown(_:))) && ran.names.isEmpty)
        #expect(returnInFilter() && ran.names == ["cov_alpha"])
    }

    /// The category pop-up limits the list; the user commands are one category, however they came.
    @Test
    internal func theCategoriesLimitTheList() throws {
        defer { finish() }
        browser.show(category: CommandRow.userCategory)
        let popUp = try #require(categories)
        #expect(popUp.itemTitles.filter { $0 == CommandRow.userCategory }.count == 1)
        #expect(popUp.itemTitles.last == CommandRow.userCategory)
        #expect(browser.rows.map(\.id) == ["em_mine"])
        popUp.selectItem(at: 0)
        popUp.sendAction(popUp.action, to: popUp.target)
        #expect(browser.rows.count > 1)
    }

    /// Return in the list runs the selected command.
    @Test
    internal func returnInTheListRunsTheCommand() throws {
        defer { finish() }
        browser.show(category: nil)
        type("cov_alpha")
        let table = try #require(list?.tableView)
        table.keyDown(with: try #require(key("\r", code: 36)))
        #expect(ran.names == ["cov_alpha"])
    }

    /// Cmd+C in the list copies the command's name; elsewhere it is left to the window.
    @Test
    internal func commandCCopiesTheName() throws {
        defer { finish() }
        browser.show(category: nil)
        type("cov_alpha")
        let window = try #require(browser.window)
        let copy = try #require(key("c", code: 8, .command))
        _ = window.performKeyEquivalent(with: copy)
        #expect(stage.pasteboard.string(forType: .string) == nil)
        window.makeFirstResponder(list?.tableView)
        #expect(window.performKeyEquivalent(with: copy))
        #expect(stage.pasteboard.string(forType: .string) == "cov_alpha")
        // A window whose dialog is gone copies nothing.
        let orphan = try autoreleasepool { try #require(CommandBrowserController(center: stage.center).window) }
        stage.pasteboard.clearContents()
        _ = orphan.performKeyEquivalent(with: copy)
        #expect(stage.pasteboard.string(forType: .string) == nil)
        orphan.close()
    }

    /// An editor picks a command with OK; closing the dialog picks none; a second pick while one runs gets none.
    @Test
    internal func pickingForAnEditor() {
        defer { finish() }
        var nested: CommandRow? = CommandRow(id: "unchanged", title: "", keys: "", category: "")
        stage.whilePicking = { _ in
            nested = browser.pick()
            type("cov_beta")
            press("OK")
        }
        let picked = stage.center.pickCommand()
        #expect(picked?.id == "cov_beta" && picked?.title == "Probe cov_beta")
        #expect(nested == nil && stage.modalStops == 1 && ran.names.isEmpty)
        stage.whilePicking = { $0.close() }
        #expect(stage.center.pickCommand() == nil && stage.modalStops == 2)
    }

    /// New, Edit, Delete and Rename/Copy manage the user commands.
    @Test
    internal func theUserCommandsAreManagedHere() {
        defer { finish() }
        browser.show(category: CommandRow.userCategory)
        stage.interaction.formAnswers = [.cancel, .values(["name": .text("fresh")])]
        press("New…")
        press("New…")
        #expect(Set(browser.rows.map(\.id)) == ["em_fresh", "em_mine"])
        list?.selectedRow = row("em_mine")
        stage.interaction.formAnswers = [.values(["title": .text("Mine, better")])]
        press("Edit…")
        #expect(stage.center.userCommand(named: "em_mine")?.title == "Mine, better")
        list?.selectedRow = row("em_fresh")
        stage.interaction.choiceAnswers = [1, 0]
        press("Delete")
        #expect(stage.center.userCommand(named: "em_fresh") != nil)
        press("Delete")
        #expect(stage.center.userCommand(named: "em_fresh") == nil && browser.rows.map(\.id) == ["em_mine"])
        list?.selectedRow = row("em_mine")
        stage.interaction.formAnswers = [
            .cancel,
            .values(["name": .text("mine")]),
            .values(["name": .text("copy")], button: 1),
            .values(["name": .text("moved")], button: 0)
        ]
        for _ in 0..<4 { press("Rename/Copy…") }
        #expect(stage.interaction.log.contains("inform: The name cannot be used"))
        // The copy is selected afterwards, so it is the one renamed.
        #expect(stage.center.store.userCommands.map(\.name).sorted() == ["em_mine", "em_moved"])
        // Without a selected user command the buttons do nothing.
        list?.selectedRow = nil
        stage.interaction.formAnswers = [.accept]
        press("Edit…")
        press("Delete")
        press("Rename/Copy…")
        #expect(stage.interaction.formAnswers.count == 1)
    }
}
