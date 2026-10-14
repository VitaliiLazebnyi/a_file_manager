import AFMKernel
import AppKit

/// The function-key bar at the bottom of the window (spec 02 › Function-key bar): a button for
/// each plain function key that is bound to a command with a bar caption, plus Exit. While
/// Shift, Option or Control is held the bar shows what the function keys do with that
/// modifier. The bar follows the key bindings and knows no command itself. Main thread only.
final class FunctionKeyBar: NSView {
    struct Entry: Equatable {
        let title: String
        /// Nil for Exit.
        let command: CommandID?
    }

    private let kernel: Kernel
    private let stack = NSStackView()
    private(set) var entries: [Entry] = []
    private(set) var modifiers: KeyModifiers = []
    private var buttons: [NSButton] = []

    init(kernel: Kernel) {
        self.kernel = kernel
        super.init(frame: .zero)
        stack.distribution = .fillEqually
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        show([])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// What the bar shows while `modifiers` are held. The plain bar has only the commands that
    /// bring a bar caption (F1 and F2 have no button, to save space); with a modifier every
    /// bound function key is shown, under its bar caption or its menu title.
    static func entries(for modifiers: KeyModifiers, commands: CommandRegistry, keys: KeyBindings) -> [Entry] {
        var entries: [Entry] = []
        for number in 1...12 {
            let shortcut = Shortcut.f(number, modifiers)
            guard let id = keys.command(for: shortcut), let command = commands[id] else { continue }
            if modifiers.isEmpty {
                guard let label = command.barLabel else { continue }
                entries.append(Entry(title: "F\(number) \(label)", command: id))
            } else {
                let label = command.barLabel ?? command.title.replacingOccurrences(of: "…", with: "")
                entries.append(Entry(title: "\(shortcut.displayText) \(label)", command: id))
            }
        }
        entries.append(Entry(title: "⌘Q Exit", command: nil))
        return entries
    }

    /// Shows the bar of a modifier state; only Shift, Option and Control count.
    func show(_ held: KeyModifiers) {
        let held = held.contains(.command) ? [] : held.intersection([.shift, .option, .control])
        let shown = FunctionKeyBar.entries(for: held, commands: kernel.commands, keys: kernel.keyBindings)
        modifiers = held
        guard shown != entries else { return }
        entries = shown
        buttons.forEach { $0.removeFromSuperview() }
        buttons = shown.map { entry in
            let button = entry.command == nil
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
        buttons.forEach(stack.addArrangedSubview)
        validate()
    }

    /// A button whose command cannot run now is greyed out, like its menu entry.
    func validate() {
        for button in buttons {
            guard let name = button.identifier?.rawValue else { continue }
            let isEnabled = kernel.commands.isEnabled(CommandID(rawValue: name))
            if button.isEnabled != isEnabled { button.isEnabled = isEnabled }
        }
    }

    /// Whether the button of a command can be pressed; nil when the bar does not show it.
    func isEnabled(_ command: CommandID) -> Bool? {
        buttons.first { $0.identifier?.rawValue == command.rawValue }?.isEnabled
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        if let name = sender.identifier?.rawValue { kernel.commands.perform(CommandID(rawValue: name)) }
    }
}
