import AFMKernel
import AppKit

/// The window of the Multi-Rename Tool (spec 09 › Window and scope).
///
/// It only shows a `MultiRenameSession` and passes on what the user does; everything it does is on
/// the main thread, and the session keeps the work off it.
internal final class MultiRenameWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate,
    NSTextFieldDelegate, NSComboBoxDelegate
{
    /// Shows an open panel as a sheet of a window, then hands the button and the locations chosen to the
    /// function given.
    internal typealias OpenPanelPresenter =
        (NSOpenPanel, NSWindow, @escaping (NSApplication.ModalResponse, [URL]) -> Void) -> Void

    /// The kind of the rows of the list's own drag.
    internal static let rowType = NSPasteboard.PasteboardType("afm.multirename.row")

    /// The date column's format.
    internal static let dateFormatter: DateFormatter = {
        let made = DateFormatter()
        made.dateStyle = .short
        made.timeStyle = .medium
        return made
    }()

    /// Called when the window has closed, so that its owner can let go of it.
    internal var onClose: (() -> Void)?
    /// Opens a menu under a button.
    ///
    /// The program shows the real menu; a test records it.
    internal var popUpMenu: (NSMenu, NSView) -> Void = { menu, view in
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 2), in: view)
    }
    /// Opens the menu of a pull-down button, as a click on it does.
    ///
    /// A test records it instead.
    internal var clickPopUp: (NSPopUpButton) -> Void = { $0.performClick(nil) }
    /// Shows an open panel as a sheet of the window and hands on the button and the locations
    /// chosen.
    ///
    /// The program shows the real panel; a test answers in its place.
    internal var presentOpenPanel: OpenPanelPresenter = { panel, window, done in
        panel.beginSheetModal(for: window) { done($0, panel.urls) }
    }

    /// Unowned: the kernel owns the plugin, and through it this.
    internal unowned let kernel: Kernel
    /// The state of the tool, which the window shows.
    internal let session: MultiRenameSession
    /// The window, which this controller keeps for as long as it lives.
    internal let toolWindow: Window
    /// The rename mask for the name, with its history.
    internal let nameMaskBox = NSComboBox()
    /// The rename mask for the extension.
    internal let extensionField = NSTextField()
    /// "Search for", with its history.
    internal let searchBox = NSComboBox()
    /// "Replace with", with its history.
    internal let replaceBox = NSComboBox()
    /// `^`: respect upper and lower case.
    internal let caseBox = NSButton(checkboxWithTitle: "^", target: nil, action: nil)
    /// `1x`: replace only the first occurrence.
    internal let onceBox = NSButton(checkboxWithTitle: "1x", target: nil, action: nil)
    /// `[E]`: also search the extension.
    internal let extensionBox = NSButton(checkboxWithTitle: "[E]", target: nil, action: nil)
    /// "RegEx".
    internal let regexBox = NSButton(checkboxWithTitle: "RegEx", target: nil, action: nil)
    /// "Subst.".
    internal let substituteBox = NSButton(checkboxWithTitle: "Subst.", target: nil, action: nil)
    /// "Upper/lowercase", in the order of `LetterCase.allCases`.
    internal let letterCasePopup = NSPopUpButton()
    /// "Start at" of the counter.
    internal let startField = NSTextField()
    /// "Step by" of the counter.
    internal let stepField = NSTextField()
    /// The stepper of "Start at".
    internal let startStepper = NSStepper()
    /// The stepper of "Step by".
    internal let stepStepper = NSStepper()
    /// "Digits": 1 to 10, then automatic.
    internal let digitsPopup = NSPopUpButton()
    /// "F2 Load/save settings".
    internal let settingsPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    /// "F10 Names".
    internal let namesPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    /// The list of the items.
    internal let table = ListView()
    /// The line under the list: what the preview found, or what is wrong.
    internal let statusLabel = NSTextField(labelWithString: "")
    /// "Next step (F5)".
    internal let nextStepButton = NSButton(title: "↻ Next step (F5)", target: nil, action: nil)
    /// "Start!".
    internal let startButton = NSButton(title: "Start!", target: nil, action: nil)
    /// "Undo".
    internal let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    /// "Result list".
    internal let resultButton = NSButton(title: "Result list", target: nil, action: nil)
    /// "Close".
    internal let closeButton = NSButton(title: "Close", target: nil, action: nil)
    /// The buttons that insert placeholders, which given names make useless.
    internal var maskOnlyButtons: [NSButton] = []
    /// The column the list is sorted by, if any.
    internal var sortColumn: String?
    /// Whether the list is sorted upwards.
    internal var sortAscending = true
    /// The saved settings chosen last; "Delete entry" deletes these.
    internal var loadedName: String?
    /// What the histories and menus were last built from; they are built again only when it changes.
    private var shownRevision = -1
    private var shownGivenNames = false

    /// The window of `session`.
    internal init(kernel: Kernel, session: MultiRenameSession) {
        self.kernel = kernel
        self.session = session
        let window = Window(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Multi-Rename Tool"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 420)
        window.center()
        toolWindow = window
        super.init(window: window)
        window.delegate = self
        window.onKeyDown = { [weak self] event in self?.handleWindowKey(event) == true }
        buildContent(in: window)
        showSettings()
        update()
        session.onChange = { [weak self] in self?.update() }
    }

    /// The window is made in code, never from an archive.
    internal required init?(coder _: NSCoder) { nil }

    /// What the status line says about a problem of the settings.
    internal static func describe(_ problem: any Error) -> String {
        switch problem {
        case RenameMaskError.invalidPlaceholder(let text):
            return "Invalid placeholder: \(text)"

        case RenameMaskError.contentPluginsUnavailable:
            return "Content-plugin fields [=…] are not available."

        case SearchReplace.Problem.invalidExpression(let text):
            return "Invalid regular expression: \(text)"

        case SearchReplace.Problem.tooSlow(let text):
            return "The regular expression takes too long for these names: \(text)"

        default:
            return "The rename mask is invalid."
        }
    }

    /// Puts the session's settings into the fields.
    internal func showSettings() {
        let settings = session.settings
        nameMaskBox.stringValue = settings.nameMask
        extensionField.stringValue = settings.extensionMask
        searchBox.stringValue = settings.search
        replaceBox.stringValue = settings.replacement
        caseBox.state = settings.caseSensitive ? .on : .off
        onceBox.state = settings.firstOnly ? .on : .off
        extensionBox.state = settings.searchesExtension ? .on : .off
        regexBox.state = settings.regularExpression ? .on : .off
        substituteBox.state = settings.substitute ? .on : .off
        letterCasePopup.selectItem(at: settings.letterCase.rawValue)
        startField.stringValue = String(settings.counter.start)
        stepField.stringValue = String(settings.counter.step)
        startStepper.integerValue = settings.counter.start
        stepStepper.integerValue = settings.counter.step
        digitsPopup.selectItem(at: settings.counter.digits == 0 ? 10 : min(max(settings.counter.digits, 1), 10) - 1)
    }

    /// The settings the fields hold.
    internal func readFields() -> RenameSettings {
        var settings = RenameSettings()
        settings.nameMask = nameMaskBox.stringValue
        settings.extensionMask = extensionField.stringValue
        settings.search = searchBox.stringValue
        settings.replacement = replaceBox.stringValue
        settings.caseSensitive = caseBox.state == .on
        settings.firstOnly = onceBox.state == .on
        settings.searchesExtension = extensionBox.state == .on
        settings.regularExpression = regexBox.state == .on
        settings.substitute = substituteBox.state == .on
        settings.letterCase = LetterCase(rawValue: letterCasePopup.indexOfSelectedItem) ?? .unchanged
        settings.counter = CounterDefinition(
            start: Int(startField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 1,
            step: Int(stepField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 1,
            digits: digitsPopup.indexOfSelectedItem == 10 ? 0 : digitsPopup.indexOfSelectedItem + 1
        )
        return settings
    }

    /// Every change to a field shows in the preview at once.
    internal func fieldsChanged() {
        session.settings = readFields()
        update()
    }

    /// A field was typed into.
    internal func controlTextDidChange(_: Notification) {
        fieldsChanged()
    }

    /// An entry of a history was chosen.
    internal func comboBoxSelectionDidChange(_ notification: Notification) {
        // The box holds the chosen text only after this notification.
        guard let combo = notification.object as? NSComboBox, combo.indexOfSelectedItem >= 0,
            let text = combo.itemObjectValue(at: combo.indexOfSelectedItem) as? String
        else {
            return
        }
        combo.stringValue = text
        fieldsChanged()
    }

    /// Brings buttons, menus, status line and list in line with the session.
    internal func update() {
        if session.settings != readFields() {
            showSettings()
        }
        let usesMasks = session.givenNames.isEmpty
        for button in maskOnlyButtons {
            button.isEnabled = usesMasks
        }
        nameMaskBox.isEnabled = usesMasks
        extensionField.isEnabled = usesMasks
        substituteBox.isEnabled = regexBox.state == .on
        startButton.isEnabled = !session.isBusy && session.rowCount > 0
        nextStepButton.isEnabled = !session.isBusy && session.rowCount > 0
        undoButton.isEnabled = session.canUndo
        resultButton.isEnabled = session.hasResultList
        let revision = session.store.revision
        if revision != shownRevision || !usesMasks != shownGivenNames {
            (shownRevision, shownGivenNames) = (revision, !usesMasks)
            reloadHistories()
            rebuildMenus()
        }
        showStatus(usesMasks: usesMasks)
        let selection = table.selectedRowIndexes
        table.reloadData()
        table.selectRowIndexes(selection.filteredIndexSet { $0 < session.rowCount }, byExtendingSelection: false)
    }

    /// Fills the lists of the boxes from their histories, where they changed.
    internal func reloadHistories() {
        for (combo, history) in [
            (nameMaskBox, RenameStore.History.nameMask), (searchBox, .search), (replaceBox, .replacement)
        ] {
            let entries = session.store.history(history)
            if (combo.objectValues as? [String]) != entries {
                combo.removeAllItems()
                combo.addItems(withObjectValues: entries)
            }
        }
    }

    /// The search of the session's list is not wanted any more, nor is the list shown again.
    internal func windowWillClose(_: Notification) {
        // The preview under way, and one that waits out the pause, are not wanted any more.
        session.close()
        // A closed tool is not opened again: its list asks nothing more of the session or the kernel
        // (which may be gone before the views are, when the program ends).
        table.dataSource = nil
        table.delegate = nil
        onClose?()
    }

    /// The status line: a problem of the settings, the conflicts and errors, or what the start button does.
    private func showStatus(usesMasks: Bool) {
        let counts = session.counts
        if let problem = session.problem {
            statusLabel.stringValue = Self.describe(problem)
            statusLabel.textColor = .systemRed
        } else if counts.conflicts > 0 || counts.errors > 0 {
            statusLabel.stringValue = [
                counts.conflicts > 0 ? "\(counts.conflicts) name conflict(s)" : nil,
                counts.errors > 0 ? "\(counts.errors) name(s) cannot be used" : nil
            ]
            .compactMap(\.self)
            .joined(separator: ", ")
            statusLabel.textColor = .systemRed
        } else {
            statusLabel.stringValue =
                usesMasks
                ? "Please press 'Start!' to start renaming!"
                : "The names come from a list. Please press 'Start!' to start renaming!"
            statusLabel.textColor = .labelColor
        }
    }

    private func rebuildMenus() {
        func fill(_ popup: NSPopUpButton, _ title: String, _ entries: [MenuEntry]) {
            popup.removeAllItems()
            popup.addItem(withTitle: title)
            for entry in entries {
                if entry.caption.isEmpty {
                    popup.menu?.addItem(.separator())
                    continue
                }
                let item = NSMenuItem(title: entry.caption, action: nil, keyEquivalent: "")
                item.representedObject = entry.tag
                item.isEnabled = entry.isEnabled
                popup.menu?.addItem(item)
            }
            popup.autoenablesItems = false
        }
        let saved = session.store.savedNames
        fill(
            settingsPopup,
            "F2 Load/save settings",
            [
                MenuEntry(caption: "<default>", tag: "default", isEnabled: true),
                MenuEntry(caption: "Save settings…", tag: "save", isEnabled: true),
                MenuEntry(caption: "Delete entry…", tag: "delete", isEnabled: !saved.isEmpty),
                MenuEntry(caption: "", tag: "", isEnabled: false)
            ]
                + saved.map { MenuEntry(caption: $0, tag: "load:" + $0, isEnabled: true) }
        )
        fill(
            namesPopup,
            "F10 Names",
            [
                MenuEntry(caption: "Load names from file…", tag: "load", isEnabled: true),
                MenuEntry(caption: "Edit names…", tag: "edit", isEnabled: true),
                MenuEntry(caption: "Use the rename masks again", tag: "masks", isEnabled: !session.givenNames.isEmpty)
            ]
        )
    }
}
