import AFMKernel
import AppKit

/// The function-key bar at the bottom of the window (spec 02 › Function-key bar).
///
/// A button for each plain function key that is bound to a command with a bar caption, plus
/// Exit. While Shift, Option or Control is held the bar shows what the function keys do with
/// that modifier. The bar follows the key bindings and knows no command itself. Main thread
/// only.
internal final class FunctionKeyBar: NSView {
    /// One button of the bar.
    internal struct Entry: Equatable {
        /// The key and what it does, `F5 Copy`.
        internal let title: String
        /// The command; nil for Exit.
        internal let command: CommandID?
    }

    /// What the bar shows, in order.
    internal private(set) var entries: [Entry] = []
    /// The buttons of `entries`.
    internal private(set) var buttons: [NSButton] = []
    /// The kernel whose key bindings and commands the bar shows.
    private let kernel: Kernel
    /// The row of buttons, all of one width.
    private let stack = NSStackView()

    /// The bar of `kernel`, as it is without a modifier.
    internal init(kernel: Kernel) {
        self.kernel = kernel
        super.init(frame: .zero)
        stack.distribution = .fillEqually
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        addFilling(stack)
        show([])
    }

    /// Not used: the view is made in code.
    @available(*, unavailable)
    internal required init?(coder _: NSCoder) {
        fatalError("not used")
    }

    /// What the bar shows while `modifiers` are held.
    ///
    /// The plain bar has only the commands that bring a bar caption (F1 and F2 have no button,
    /// to save space); with a modifier every bound function key is shown, under its bar caption
    /// or its menu title.
    internal static func entries(for modifiers: KeyModifiers, commands: CommandRegistry, keys: KeyBindings) -> [Entry] {
        var shown: [Entry] = []
        for number in 1...12 {
            let shortcut = Shortcut.f(number, modifiers)
            guard let id = keys.command(for: shortcut), let command = commands[id] else {
                continue
            }
            if modifiers.isEmpty {
                guard let label = command.barLabel else {
                    continue
                }
                shown.append(Entry(title: "F\(number) \(label)", command: id))
            } else {
                let label = command.barLabel ?? command.title.replacingOccurrences(of: "…", with: "")
                shown.append(Entry(title: "\(shortcut.displayText) \(label)", command: id))
            }
        }
        shown.append(Entry(title: "⌘Q Exit", command: nil))
        return shown
    }

    /// Shows the bar of a modifier state; only Shift, Option and Control count.
    internal func show(_ held: KeyModifiers) {
        let modifiers = held.contains(.command) ? [] : held.intersection([.shift, .option, .control])
        let shown = Self.entries(for: modifiers, commands: kernel.commands, keys: kernel.keyBindings)
        guard shown != entries else {
            return
        }
        entries = shown
        for button in buttons {
            button.removeFromSuperview()
        }
        buttons = shown.map(makeButton(for:))
        for button in buttons {
            stack.addArrangedSubview(button)
        }
        validate()
    }

    /// A button whose command cannot run now is greyed out, like its menu entry.
    internal func validate() {
        for button in buttons {
            guard let name = button.identifier?.rawValue else {
                continue
            }
            let isEnabled = kernel.commands.isEnabled(CommandID(rawValue: name))
            if button.isEnabled != isEnabled {
                button.isEnabled = isEnabled
            }
        }
    }

    /// The button of `entry`; Exit quits the program.
    private func makeButton(for entry: Entry) -> NSButton {
        let button =
            entry.command == nil
            ? NSButton(title: entry.title, target: NSApp, action: #selector(NSApplication.terminate(_:)))
            : NSButton(title: entry.title, target: self, action: #selector(buttonPressed(_:)))
        button.identifier = entry.command.map { NSUserInterfaceItemIdentifier($0.rawValue) }
        button.bezelStyle = .recessed
        button.refusesFirstResponder = true
        button.lineBreakMode = .byTruncatingTail
        button.toolTip = entry.title
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    /// A button was pressed: its command runs.
    @objc
    private func buttonPressed(_ sender: NSButton) {
        if let name = sender.identifier?.rawValue {
            kernel.commands.perform(CommandID(rawValue: name))
        }
    }

    deinit {
        // Nothing to release.
    }
}
