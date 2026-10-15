import AFMContracts
import AFMKernel
import AppKit

/// The command line below the panels (spec 02 › Command line).
///
/// A prompt with the source panel's path and a combo box that remembers what was run. What a
/// line does is decided by `CommandLineAction`; the shell itself only knows `cd`, the names of
/// the registered commands, and whom to hand everything else to. Main thread only.
internal final class CommandLineView: NSView, NSComboBoxDelegate {
    /// The commands of the line itself, which keep their keys while it is typed in.
    internal static let ownCommands: Set<CommandID> = [
        .addNameToCommandLine, .addPathAndNameToCommandLine, .addPathToCommandLine, .commandLineHistory,
        .clearCommandLine, .previousCommandLine, .nextCommandLine
    ]

    /// The lines run before.
    internal let history: CommandLineHistory
    /// The source panel's path, in front of the field.
    internal let prompt = NSTextField(labelWithString: "")
    /// Where the line is typed.
    internal let field = CommandLineField()
    /// The kernel whose commands the line runs.
    private let kernel: Kernel
    /// The panels, whose source panel the line works in.
    private let panels: PanelCoordinator
    /// The panel events listened to; the kernel stops calling once they are let go of.
    private var subscriptions: [AnyObject] = []
    /// Where Ctrl+E is in the history; -1 while the line is the user's own.
    private var recalled = -1

    /// What is on the line; setting it puts the caret behind it while the line is typed in.
    internal var text: String {
        get { field.stringValue }
        set {
            field.stringValue = newValue
            field.currentEditor()?.selectedRange = NSRange(location: newValue.utf16.count, length: 0)
        }
    }

    /// Whether the line is being typed in.
    internal var hasFocus: Bool { field.currentEditor() != nil }

    /// Whether the list of the lines run before is open.
    internal var isHistoryOpen: Bool { field.cell?.isAccessibilityExpanded() ?? false }

    /// The command line of `kernel`, in the source panel of `panels`.
    internal init(kernel: Kernel, panels: PanelCoordinator) {
        self.kernel = kernel
        self.panels = panels
        history = CommandLineHistory(settings: kernel.settings)
        super.init(frame: .zero)
        arrangeParts()
        reloadHistory()
        updatePrompt()
        // The prompt follows the source panel wherever it goes.
        let subscription = kernel.panelEvents.subscribe { [weak self] event, _ in
            if event == .locationChanged || event == .becameSource {
                self?.updatePrompt()
            }
        }
        subscriptions.append(subscription)
    }

    /// Not used: the view is made in code.
    @available(*, unavailable)
    internal required init?(coder _: NSCoder) {
        fatalError("not used")
    }

    /// The source panel's path as its file system writes it, and `>`.
    internal func updatePrompt() {
        let path = kernel.fileSystems.displayPath(panels.sourcePanel.model.directory)
        prompt.stringValue = path + ">"
        prompt.toolTip = path
    }

    /// Puts the caret at the end of the line.
    internal func focusField() {
        guard window?.makeFirstResponder(field) == true else {
            return
        }
        field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.utf16.count, length: 0)
    }

    /// Gives the keyboard back to the source panel's file list.
    internal func returnToFileList() {
        panels.sourcePanel.focus()
    }

    /// Runs what is on the line (Enter); returns whether it ran.
    ///
    /// The line is cleared and remembered when it could be run; when nothing takes it (no
    /// plugin runs programs, or a job is under way) the command registry beeps and the line
    /// stays for another try.
    @discardableResult
    internal func execute() -> Bool {
        let typed = text
        // A line that begins with a blank is kept out of every history (`CommandLineHistory`);
        // whoever runs it has the same rule and has to see the blank to keep it.
        let isPrivate = CommandLineHistory.isPrivate(typed)
        let commands = kernel.commands
        let done: Bool
        switch CommandLineAction(line: typed, commands: commands) {
        case .openCursorItem:
            returnToFileList()
            return commands.perform(.open)

        case .changeDirectory(let path):
            noteTypedLocation(path)
            done = commands.perform(.changeDirectory, .text(path))

        case .command(let id, let argument):
            done = commands.perform(id, argument)

        case .run(let line):
            done = commands.perform(.runCommandLine, .text(isPrivate ? " " + line : line))
        }
        guard done else {
            return false
        }
        history.add(typed)
        reloadHistory()
        clear()
        returnToFileList()
        return true
    }

    /// Empties the line.
    internal func clear() {
        recalled = -1
        text = ""
    }

    /// Adds text at the end of the line and moves the caret there, so Enter runs the line.
    internal func append(_ addition: String) {
        text = CommandLineAction.appending(addition, to: text)
        focusField()
    }

    /// Ctrl+Enter and Ctrl+Shift+Enter: the name of the item under the cursor, or its whole path.
    internal func addCursorItem(withPath: Bool) {
        guard let item = panels.sourcePanel.model.cursorItem else {
            return
        }
        append(CommandLineAction.quoted(withPath ? kernel.fileSystems.displayPath(item.url) : item.name) + " ")
    }

    /// Ctrl+P: the path of the source panel.
    internal func addPath() {
        let path = kernel.fileSystems.displayPath(panels.sourcePanel.model.directory)
        append(CommandLineAction.quoted(path.hasSuffix("/") ? path : path + "/"))
    }

    /// Ctrl+E: `step` 1 brings back the line run before the one shown, -1 the one run after it.
    internal func recall(_ step: Int) {
        let position = min(history.entries.count - 1, max(-1, recalled + step))
        recalled = position
        text = position >= 0 ? history.entries[position] : ""
        focusField()
    }

    /// Opens the list of the lines run before, or closes it.
    internal func showHistory() {
        // Remembering may have been switched off since the list was filled.
        if history.forgetIfSwitchedOff() {
            reloadHistory()
        }
        focusField()
        guard !history.entries.isEmpty, hasFocus else {
            return
        }
        field.cell?.setAccessibilityExpanded(!isHistoryOpen)
    }

    /// The keys of a text field that the line handles itself.
    ///
    /// Enter runs the line, Esc empties it and goes back to the file list, Tab goes back to
    /// it, ↑ and ↓ move the file list's cursor. While the list of earlier lines is open, the
    /// arrows, Enter and Esc are its own.
    internal func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        if isHistoryOpen {
            return false
        }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            execute()

        case #selector(NSResponder.cancelOperation(_:)):
            clear()
            returnToFileList()

        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            returnToFileList()

        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
            // ↑ and ↓ belong to the file list even from here; the line keeps its text.
            let model = panels.sourcePanel.model
            returnToFileList()
            model.moveCursor(to: model.cursor + (selector == #selector(NSResponder.moveUp(_:)) ? -1 : 1))

        default:
            return false
        }
        return true
    }

    /// The user typed: Ctrl+E starts from the newest line again.
    internal func controlTextDidChange(_: Notification) {
        recalled = -1
    }

    /// The prompt and the field side by side, the field taking half the width.
    private func arrangeParts() {
        prompt.alignment = .right
        prompt.lineBreakMode = .byTruncatingHead
        prompt.font = .systemFont(ofSize: 12)
        prompt.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.usesDataSource = false
        field.completes = true
        field.numberOfVisibleItems = CommandLineHistory.limit
        field.font = .systemFont(ofSize: 12)
        field.delegate = self
        field.onKey = { [weak self] in self?.handleKey($0) ?? false }
        field.setAccessibilityLabel("Command line")
        for part in [prompt, field] {
            part.translatesAutoresizingMaskIntoConstraints = false
            addSubview(part)
        }
        NSLayoutConstraint.activate([
            prompt.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            prompt.trailingAnchor.constraint(equalTo: field.leadingAnchor, constant: -4),
            prompt.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            field.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.5),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
        ])
    }

    /// Fills the combo box's list with the history.
    private func reloadHistory() {
        field.removeAllItems()
        field.addItems(withObjectValues: history.entries)
    }

    /// The user typed this path just now: whoever connects to servers is told that the
    /// address is the user's own choice (`ServerConsentService`).
    ///
    /// An address read from a tab file, a list or a link never is.
    private func noteTypedLocation(_ path: String) {
        guard let consent = kernel.services.find((any ServerConsentService).self) else {
            return
        }
        let location = kernel.fileSystems.location(from: path, relativeTo: panels.sourcePanel.model.directory)
        guard (try? kernel.fileSystems.provider(for: location))?.connectsToServer == true else {
            return
        }
        consent.userChose(location)
    }

    /// The keys the line keeps for itself while it is typed in: its own commands, and Ctrl+Y,
    /// Ctrl+W, Ctrl+T and Ctrl+A as in Total Commander's line.
    private func handleKey(_ event: NSEvent) -> Bool {
        if let command = kernel.keyBindings.command(for: event), Self.ownCommands.contains(command) {
            kernel.commands.perform(command)
            return true
        }
        guard KeyModifiers(event.modifierFlags) == .control, let editor = field.currentEditor() else {
            return false
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "y":
            clear()

        case "w":
            editor.deleteWordBackward(nil)

        case "t":
            editor.deleteWordForward(nil)

        case "a":
            editor.selectAll(nil)

        default:
            return false
        }
        return true
    }

    deinit {
        // Nothing to release.
    }
}
