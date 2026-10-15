import AFMContracts
import AFMKernel
import AppKit

/// The combo box of the command line. While it is being typed in, its own keys come before
/// the menu's: Ctrl+W deletes a word here and closes a folder tab only in a panel
/// (spec 02 › Keys in the command line).
final class CommandLineField: NSComboBox {
    /// Returns true when the key was used up.
    var onKey: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, currentEditor() != nil, onKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// The command line below the panels (spec 02 › Command line): a prompt with the source
/// panel's path and a combo box that remembers what was run. What a line does is decided by
/// `CommandLineAction`; the shell itself only knows `cd`, the names of the registered commands,
/// and whom to hand everything else to. Main thread only.
final class CommandLineView: NSView, NSComboBoxDelegate {
    private let kernel: Kernel
    private let panels: PanelCoordinator
    let history: CommandLineHistory
    let prompt = NSTextField(labelWithString: "")
    let field = CommandLineField()
    /// The panel events listened to; the kernel stops calling once they are let go of.
    private var subscriptions: [AnyObject] = []
    /// Where Ctrl+E is in the history; -1 while the line is the user's own.
    private var recalled = -1

    /// The commands of the line itself, which keep their keys while it is typed in.
    static let ownCommands: Set<CommandID> = [
        .addNameToCommandLine, .addPathAndNameToCommandLine, .addPathToCommandLine, .commandLineHistory,
        .clearCommandLine, .previousCommandLine, .nextCommandLine
    ]

    init(kernel: Kernel, panels: PanelCoordinator) {
        self.kernel = kernel
        self.panels = panels
        history = CommandLineHistory(settings: kernel.settings)
        super.init(frame: .zero)

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
        reloadHistory()
        updatePrompt()
        // The prompt follows the source panel wherever it goes.
        let subscription = kernel.panelEvents.subscribe { [weak self] event, _ in
            if event == .locationChanged || event == .becameSource { self?.updatePrompt() }
        }
        subscriptions.append(subscription)
    }

    required init?(coder _: NSCoder) { fatalError("not used") }

    var text: String {
        get { field.stringValue }
        set {
            field.stringValue = newValue
            // While the line is typed in, the caret goes behind what was put there.
            field.currentEditor()?.selectedRange = NSRange(location: (newValue as NSString).length, length: 0)
        }
    }

    /// The source panel's path as its file system writes it, and `>`.
    func updatePrompt() {
        let path = kernel.fileSystems.displayPath(panels.sourcePanel.model.directory)
        prompt.stringValue = path + ">"
        prompt.toolTip = path
    }

    private func reloadHistory() {
        field.removeAllItems()
        field.addItems(withObjectValues: history.entries)
    }

    // MARK: Focus

    /// Puts the caret at the end of the line.
    func focusField() {
        guard window?.makeFirstResponder(field) == true else { return }
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
    }

    var hasFocus: Bool { field.currentEditor() != nil }

    func returnToFileList() {
        panels.sourcePanel.focus()
    }

    // MARK: Running a line

    /// Runs what is on the line (Enter). The line is cleared and remembered when it could be
    /// run; when nothing takes it (no plugin runs programs, or a job is under way) the command
    /// registry beeps and the line stays for another try.
    @discardableResult
    func execute() -> Bool {
        let typed = text
        let line = typed.trimmingCharacters(in: .whitespaces)
        // A line that begins with a blank is kept out of every history (`CommandLineHistory`);
        // whoever runs it has the same rule and has to see the blank to keep it.
        let isPrivate = CommandLineHistory.isPrivate(typed)
        let commands = kernel.commands
        let done: Bool
        switch CommandLineAction(line: line, commands: commands) {
        case .openCursorItem:
            returnToFileList()
            return commands.perform(.open)

        case .changeDirectory(let path):
            noteTypedLocation(path)
            done = commands.perform(.changeDirectory, .text(path))

        case .command(let id, let argument): done = commands.perform(id, argument)
        case .run(let line): done = commands.perform(.runCommandLine, .text(isPrivate ? " " + line : line))
        }
        guard done else { return false }
        history.add(typed)
        reloadHistory()
        clear()
        returnToFileList()
        return true
    }

    /// The user typed this path just now: whoever connects to servers is told that the
    /// address is the user's own choice (`ServerConsentService`), which an address read from
    /// a tab file, a list or a link never is.
    private func noteTypedLocation(_ path: String) {
        guard let consent = kernel.services.find((any ServerConsentService).self) else { return }
        let location = kernel.fileSystems.location(from: path, relativeTo: panels.sourcePanel.model.directory)
        guard (try? kernel.fileSystems.provider(for: location))?.connectsToServer == true else { return }
        consent.userChose(location)
    }

    func clear() {
        recalled = -1
        text = ""
    }

    /// Adds text at the end of the line and moves the caret there, so Enter runs the line.
    func append(_ addition: String) {
        text = CommandLineAction.appending(addition, to: text)
        focusField()
    }

    /// Ctrl+Enter and Ctrl+Shift+Enter: the name of the item under the cursor, or its whole path.
    func addCursorItem(withPath: Bool) {
        guard let item = panels.sourcePanel.model.cursorItem else { return }
        append(CommandLineAction.quoted(withPath ? kernel.fileSystems.displayPath(item.url) : item.name) + " ")
    }

    /// Ctrl+P: the path of the source panel.
    func addPath() {
        let path = kernel.fileSystems.displayPath(panels.sourcePanel.model.directory)
        append(CommandLineAction.quoted(path.hasSuffix("/") ? path : path + "/"))
    }

    /// Ctrl+E: `step` 1 brings back the line run before the one shown, -1 the one run after it.
    func recall(_ step: Int) {
        let position = min(history.entries.count - 1, max(-1, recalled + step))
        recalled = position
        text = position >= 0 ? history.entries[position] : ""
        focusField()
    }

    // MARK: The history list

    var isHistoryOpen: Bool { field.cell?.isAccessibilityExpanded() ?? false }

    func showHistory() {
        // Remembering may have been switched off since the list was filled.
        if history.forgetIfSwitchedOff() { reloadHistory() }
        focusField()
        guard !history.entries.isEmpty, hasFocus else { return }
        field.cell?.setAccessibilityExpanded(!isHistoryOpen)
    }

    // MARK: Keys

    /// The keys the line keeps for itself while it is typed in.
    private func handleKey(_ event: NSEvent) -> Bool {
        if let command = kernel.keyBindings.command(for: event), Self.ownCommands.contains(command) {
            kernel.commands.perform(command)
            return true
        }
        guard KeyModifiers(event.modifierFlags) == .control, let editor = field.currentEditor() else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "y": clear()
        case "w": editor.deleteWordBackward(nil)
        case "t": editor.deleteWordForward(nil)
        case "a": editor.selectAll(nil)
        default: return false
        }
        return true
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        // While the list is open, the arrows, Enter and Esc are its own.
        if isHistoryOpen { return false }
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

    func controlTextDidChange(_: Notification) {
        recalled = -1
    }
}
