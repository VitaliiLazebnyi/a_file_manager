import Foundation

/// The buttons of the button bar (spec 02 › Button bars). Plugins say which of their commands
/// deserve a button and with which picture; the shell draws the bar. The user's own layout,
/// kept in the settings, replaces the plugins' proposal.
public final class ToolbarRegistry {
    public struct Button: Equatable {
        public let command: CommandID
        /// The name of a system symbol, e.g. `doc.on.doc`.
        public let symbol: String

        public init(command: CommandID, symbol: String) {
            self.command = command
            self.symbol = symbol
        }
    }

    /// Settings key of the user's layout: command names in order, an empty text for a
    /// separator.
    public static let settingsKey = "toolbar.layout"

    private var contributions: [(group: Int, button: Button)] = []
    private var symbols: [CommandID: String] = [:]
    /// Called on the main thread when the layout changed and the bar must be drawn again.
    public var onChange: (() -> Void)?

    public init() {}

    /// Proposes a button. Buttons are shown by `group` in ascending order, with a separator
    /// between groups; inside a group, in the order they were added.
    public func add(_ command: CommandID, symbol: String, group: Int) {
        contributions.append((group, Button(command: command, symbol: symbol)))
        symbols[command] = symbol
    }

    /// Gives a command a picture without proposing a button for it; the user can then put it
    /// on the bar.
    public func setSymbol(_ symbol: String, for command: CommandID) {
        symbols[command] = symbol
    }

    public func symbol(for command: CommandID) -> String? { symbols[command] }

    /// The plugins' proposal; nil is a separator.
    public var defaultLayout: [Button?] {
        var layout: [Button?] = []
        for group in Set(contributions.map(\.group)).sorted() {
            if !layout.isEmpty { layout.append(nil) }
            layout += contributions.filter { $0.group == group }.map { Optional($0.button) }
        }
        return layout
    }

    /// The bar as it is to be drawn: the user's layout when there is one, else the proposal.
    public func layout(from settings: SettingsStore) -> [Button?] {
        guard let names = settings.value([String].self, forKey: ToolbarRegistry.settingsKey) else { return defaultLayout }
        return names.map { name in
            name.isEmpty ? nil : Button(command: CommandID(rawValue: name), symbol: symbols[CommandID(rawValue: name)] ?? "square.dashed")
        }
    }

    /// Stores the user's layout (nil goes back to the proposal) and has the bar redrawn.
    public func setLayout(_ layout: [CommandID?]?, in settings: SettingsStore) {
        if let layout {
            settings.set(layout.map { $0?.rawValue ?? "" }, forKey: ToolbarRegistry.settingsKey)
        } else {
            settings.set(nil as Data?, forKey: ToolbarRegistry.settingsKey)
        }
        onChange?()
    }
}
