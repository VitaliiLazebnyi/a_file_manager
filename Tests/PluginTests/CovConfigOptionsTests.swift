import AFMContracts
import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// The Options window and its pages, driven as the user would, with nothing put on screen.
@MainActor @Suite internal struct CovConfigOptions {
    private let stage: CovConfigStage
    private let windows = StabilityWindows { ["Options", "Choose Command"].contains($0.title) }
    private let ran = Ran()

    /// The names the probe commands were run with.
    @MainActor
    private final class Ran {
        var names: [String] = []

        deinit {
            // Nothing to release.
        }
    }

    internal init() throws {
        stage = try CovConfigStage()
        stage.bench.kernel.preferences.add(
            PreferencePage(
                title: "Demo",
                preferences: [
                    Preference("demo.flag", "Flag", .flag(default: false)),
                    Preference("demo.text", "Text", .text(default: "x")),
                    Preference("demo.choice", "Choice", .choice(["a", "b"], default: 0))
                ]
            )
        )
        for name in ["cov_alpha", "cov_beta"] {
            stage.commands.register(Command(CommandID(rawValue: name), "Probe \(name)")) { [ran] in
                ran.names.append(name)
            }
        }
    }

    /// Opens the window on a page.
    private func open(_ section: OptionsWindowController.Section) throws -> OptionsWindowController {
        stage.center.showOptions(section)
        return try #require(stage.center.optionsWindow)
    }

    private func content(_ options: OptionsWindowController) -> NSView? { options.window?.contentView }

    /// Selects the page of the demo preferences in the list of pages.
    private func showDemo(_ options: OptionsWindowController) throws {
        let pages = try #require(CovConfigStage.views(RowsTable.self, in: content(options)).first)
        pages.selectedRow = options.pageTitles.firstIndex(of: "Demo")
    }

    /// The list of the page shown (the list of pages is the first).
    private func pageTable(_ options: OptionsWindowController) -> RowsTable? {
        CovConfigStage.views(RowsTable.self, in: content(options)).dropFirst().first
    }

    private func press(_ title: String, _ options: OptionsWindowController) {
        #expect(CovConfigStage.press(title, in: content(options)), "\(title)")
    }

    private func isEnabled(_ title: String, _ options: OptionsWindowController) -> Bool {
        CovConfigStage.button(title, in: content(options))?.isEnabled == true
    }

    private func key(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags = [], in window: NSWindow?)
        -> NSEvent?
    {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: window?.windowNumber ?? 0,
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

    /// A plugin's page shows one control per preference; what is changed is stored with Apply,
    /// dropped with Cancel, and OK applies and closes.
    @Test
    internal func aPreferencePageStoresWithApply() throws {
        defer { finish() }
        let options = try open(.first)
        try showDemo(options)
        #expect(options.shownPage == "Demo" && !isEnabled("Apply", options))
        let views = content(options)
        let box = try #require(CovConfigStage.views(NSButton.self, in: views).first { $0.title == "Flag" })
        box.state = .on
        box.sendAction(box.action, to: box.target)
        #expect(isEnabled("Apply", options))
        let field = try #require(CovConfigStage.views(NSTextField.self, in: views).first { $0.stringValue == "x" })
        field.stringValue = "typed"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        let popUp = try #require(CovConfigStage.views(NSPopUpButton.self, in: views).first)
        popUp.selectItem(at: 1)
        popUp.sendAction(popUp.action, to: popUp.target)
        press("Apply", options)
        #expect(stage.settings.flag("demo.flag", default: false) && !isEnabled("Apply", options))
        #expect(stage.settings.value(String.self, forKey: "demo.text") == "typed")
        box.state = .off
        box.sendAction(box.action, to: box.target)
        press("Cancel", options)
        #expect(stage.settings.flag("demo.flag", default: false))
        // Opened again, the window shows the page selected last.
        _ = try open(.first)
        #expect(options.shownPage == "Demo")
        box.state = .off
        box.sendAction(box.action, to: box.target)
        press("OK", options)
        #expect(!stage.settings.flag("demo.flag", default: true) && options.window?.isVisible == false)
    }

    /// No page is shown while none is selected in the list.
    @Test
    internal func noPageIsShownWithoutASelection() throws {
        defer { finish() }
        let options = try open(.keyboard)
        let pages = try #require(CovConfigStage.views(RowsTable.self, in: content(options)).first)
        pages.selectedRow = nil
        #expect(options.shownPage == "Keyboard")
        pages.selectedRow = 0
        #expect(options.shownPage == options.pageTitles.first)
    }

    /// The Keyboard page: a key pressed for a command becomes its key; Esc, keys of other windows
    /// and keys without a name are not taken; keys are added, removed and reset; Apply stores them.
    @Test
    internal func theKeyboardPageRecordsKeys() async throws {
        defer { finish() }
        let options = try open(.keyboard)
        let window = options.window
        let filter = try #require(CovConfigStage.views(NSSearchField.self, in: content(options)).first)
        filter.stringValue = "cov_alpha"
        filter.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: filter))
        let table = try #require(pageTable(options))
        // Nothing selected: the buttons beep.
        table.selectedRow = nil
        for title in ["Set Shortcut…", "Remove Shortcuts"] { press(title, options) }
        #expect(stage.beeps == 2 && stage.keyHandler == nil)
        table.selectedRow = 0
        press("Set Shortcut…", options)
        let handler = try #require(stage.keyHandler)
        let other = try #require(key("k", code: 40, in: nil))
        #expect(handler(other) === other)
        #expect(handler(try #require(key("\u{1B}", code: 53, in: window))) == nil && stage.keyHandler == nil)
        press("Set Shortcut…", options)
        #expect(stage.keyHandler?(try #require(key("", code: 255, in: window))) == nil)
        press("Set Shortcut…", options)
        let all: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        #expect(stage.keyHandler?(try #require(key("k", code: 40, all, in: window))) == nil)
        let alpha: CommandID = "cov_alpha"
        let keys = { () -> String in table.tableView.numberOfRows > 0 ? self.cell(table, row: 0, column: 2) : "" }
        #expect(await AppWait.until { keys().contains("K") })
        press("Add Shortcut…", options)
        #expect(stage.keyHandler?(try #require(key("j", code: 38, .control, in: window))) == nil)
        #expect(await AppWait.until { keys().contains("⌃J") })
        #expect(isEnabled("Apply", options))
        press("Apply", options)
        #expect(stage.bench.kernel.keyBindings.shortcuts(for: alpha).count == 2)
        #expect(keys().hasSuffix("•"))
        press("Remove Shortcuts", options)
        #expect(!keys().contains("⌃J"))
        press("Reset to Default", options)
        press("Reset All", options)
        #expect(isEnabled("Apply", options))
        // Keys stored elsewhere are taken over by the page.
        #expect(stage.center.setShortcut("f8", for: "cov_beta"))
        filter.stringValue = "cov_beta"
        filter.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: filter))
        #expect(cell(table, row: 0, column: 2).contains("F8"))
        press("Set Shortcut…", options)
        press("Cancel", options)
        #expect(stage.keyHandler == nil)
    }

    /// The text of a cell of a page's list.
    private func cell(_ table: RowsTable, row: Int, column: Int) -> String {
        let view = table.tableView(table.tableView, viewFor: table.tableView.tableColumns[column], row: row)
        return (view as? NSTableCellView)?.textField?.stringValue ?? ""
    }

    /// The Button Bar page adds commands, separators and line breaks, removes and moves them,
    /// gives them pictures, and goes back to the default bar.
    @Test
    internal func theButtonBarPageEditsTheBar() throws {
        defer { finish() }
        let toolbar = stage.bench.kernel.toolbar
        toolbar.setLayout(["cm_gone", nil, ToolbarRegistry.lineBreak, .configuration], in: stage.settings)
        let options = try open(.buttonBar)
        let table = try #require(pageTable(options))
        #expect(
            cell(table, row: 0, column: 0) == "(unknown command)"
                && cell(table, row: 2, column: 0) == "═══ New line ═══"
        )
        table.selectedRow = nil
        for title in ["Remove", "Move Up", "Symbol…"] { press(title, options) }
        #expect(stage.beeps == 3)
        for row in [1, 2] {
            table.selectedRow = row
            press("Symbol…", options)
        }
        #expect(stage.beeps == 5)
        // A command that is not there is named by its name.
        table.selectedRow = 0
        stage.ui.promptAnswers = [.cancel]
        press("Symbol…", options)
        #expect(stage.ui.log.last == "prompt: Symbol for “cm_gone”: [square.dashed]")
        stage.whilePicking = { _ in }
        table.selectedRow = 3
        press("Add Command…", options)
        stage.whilePicking = { window in
            let browser = self.stage.center.browser()
            CovConfigStage.views(NSSearchField.self, in: window.contentView).first?.stringValue = "cov_beta"
            browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            CovConfigStage.press("OK", in: window.contentView)
        }
        press("Add Command…", options)
        #expect(cell(table, row: 4, column: 1) == "cov_beta" && table.selectedRow == 4)
        press("Add Separator", options)
        press("Add Line Break", options)
        #expect(table.tableView.numberOfRows == 7)
        table.selectedRow = 6
        press("Remove", options)
        press("Move Up", options)
        press("Move Down", options)
        table.selectedRow = 4
        stage.ui.promptAnswers = [.cancel, .text("no.such.symbol.here"), .text("star")]
        for _ in 0..<3 { press("Symbol…", options) }
        #expect(stage.ui.log.contains("inform: No symbol is called “no.such.symbol.here”"))
        press("Apply", options)
        #expect(toolbar.layout(from: stage.settings).count == 6)
        #expect(toolbar.symbol(for: "cov_beta") == "star")
        press("Reset to Default", options)
        press("Apply", options)
        #expect(stage.settings.data(forKey: ToolbarRegistry.settingsKey) == nil)
    }

    /// The Start Menu page adds items, commands and separators, changes, removes and moves them,
    /// and stores them with Apply.
    @Test
    internal func theStartMenuPageEditsTheMenu() throws {
        defer { finish() }
        let options = try open(.startMenu)
        let table = try #require(pageTable(options))
        table.selectedRow = nil
        for title in ["Change…", "Remove", "Move Up"] { press(title, options) }
        #expect(stage.beeps == 3)
        stage.ui.formAnswers = [
            .cancel, .values(["title": .text("Build"), "command": .text("make"), "shortcut": .text("f6")])
        ]
        press("Add Item…", options)
        press("Add Item…", options)
        #expect(cell(table, row: 0, column: 1) == "Build" && cell(table, row: 0, column: 3) == "F6")
        stage.whilePicking = { _ in }
        press("Add Command…", options)
        stage.whilePicking = { window in
            CovConfigStage.views(NSSearchField.self, in: window.contentView).first?.stringValue = "cov_alpha"
            self.stage.center.browser().controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            CovConfigStage.press("OK", in: window.contentView)
        }
        stage.ui.formAnswers = [.accept]
        press("Add Command…", options)
        #expect(cell(table, row: 1, column: 2) == "cov_alpha" && cell(table, row: 1, column: 1) == "Probe cov_alpha")
        press("Add Separator", options)
        #expect(cell(table, row: 2, column: 1) == "———")
        press("Change…", options)
        #expect(stage.beeps == 4)
        table.selectedRow = 0
        stage.ui.formAnswers = [.cancel, .values(["title": .text("Build all")])]
        press("Change…", options)
        // Return in the list changes the entry too.
        table.tableView.keyDown(with: try #require(key("\r", code: 36, in: options.window)))
        #expect(cell(table, row: 0, column: 1) == "Build all")
        press("Move Down", options)
        press("Move Up", options)
        table.selectedRow = 2
        press("Remove", options)
        press("Apply", options)
        #expect(stage.center.store.startMenu.map(\.title) == ["Build all", "Probe cov_alpha"])
        #expect(!isEnabled("Apply", options))
    }

    /// The Settings File page runs the export, import and reset commands.
    @Test
    internal func theSettingsFilePageRunsTheCommands() throws {
        defer { finish() }
        let options = try open(.settingsFile)
        #expect(options.shownPage == "Settings File")
        for title in ["Export Settings…", "Import Settings…", "Reset All Settings…"] { press(title, options) }
        #expect(stage.ui.log.first == "form: Export Settings" && stage.fileRequests.map(\.saving) == [false])
        #expect(stage.ui.log.last?.hasPrefix("choose: Reset all settings?") == true)
        press("Apply", options)
    }
}
