import Foundation

/// The buttons of the button bar (spec 02 › Button bars).
///
/// Plugins say which of their commands deserve a button and with which picture; the shell draws the bar. The user's own
/// layout, kept in the settings, replaces the plugins' proposal. Main thread.
@preconcurrency
@MainActor
public final class ToolbarRegistry {
    /// One button: a command and its picture.
    public struct Button: Equatable, Sendable {
        /// What the button runs.
        public let command: CommandID
        /// The name of a system symbol, e.g. `doc.on.doc`.
        public let symbol: String

        /// A button that runs `command`, drawn with the system symbol `symbol`.
        public init(command: CommandID, symbol: String) {
            self.command = command
            self.symbol = symbol
        }
    }

    /// Settings key of the user's layout: command names in order, an empty text for a
    /// separator.
    nonisolated public static let settingsKey = "toolbar.layout"
    /// In a layout, where the bar goes on in a new line: the groups after it start one.
    nonisolated public static let lineBreak: CommandID = "afm_ButtonBarLineBreak"

    /// Called on the main thread when the layout changed and the bar must be drawn again.
    public var onChange: (() -> Void)?
    private var contributions: [(group: Int, button: Button)] = []
    private var symbols: [CommandID: String] = [:]
    private var hints: [CommandID: String] = [:]

    /// The plugins' proposal; nil is a separator.
    public var defaultLayout: [Button?] {
        var layout: [Button?] = []
        for group in Set(contributions.map(\.group)).sorted() {
            if !layout.isEmpty { layout.append(nil) }
            layout += contributions.filter { $0.group == group }.map { Optional($0.button) }
        }
        return layout
    }

    /// No buttons yet.
    public init() {
        // Plugins propose their buttons while they start.
    }

    /// Proposes a button.
    ///
    /// Buttons are shown by `group` in ascending order, with a separator between groups; inside a group, in the order
    /// they were added. `hint` says in a sentence what the button does; the bar shows it under the command's name when
    /// the mouse rests on it.
    public func add(_ command: CommandID, symbol: String, group: Int, hint: String? = nil) {
        contributions.append((group, Button(command: command, symbol: symbol)))
        symbols[command] = symbol
        if let hint { hints[command] = hint }
    }

    /// Gives a command a picture without proposing a button for it; the user can then put it
    /// on the bar.
    public func setSymbol(_ symbol: String, for command: CommandID, hint: String? = nil) {
        symbols[command] = symbol
        if let hint { hints[command] = hint }
    }

    /// The picture of a command's button; nil when its plugin gave none.
    public func symbol(for command: CommandID) -> String? { symbols[command] }

    /// What the button of a command does, in a sentence; nil when its plugin gave none.
    public func hint(for command: CommandID) -> String? { hints[command] }

    /// The bar as it is to be drawn: the user's layout when there is one, else the proposal.
    public func layout(from settings: any SettingsStore) -> [Button?] {
        guard let names = settings.value([String].self, forKey: Self.settingsKey) else {
            return defaultLayout
        }
        return names.map { name in
            let command = CommandID(rawValue: name)
            return name.isEmpty ? nil : Button(command: command, symbol: symbols[command] ?? "square.dashed")
        }
    }

    /// Whether the user has a layout of their own, rather than the plugins' proposal.
    public func hasUserLayout(in settings: any SettingsStore) -> Bool {
        settings.data(forKey: Self.settingsKey) != nil
    }

    /// Stores the user's layout (nil in it is a separator) and has the bar redrawn.
    public func setLayout(_ layout: [CommandID?], in settings: any SettingsStore) {
        settings.set(layout.map { $0?.rawValue ?? "" }, forKey: Self.settingsKey)
        onChange?()
    }

    /// Forgets the user's layout, so that the plugins' proposal is drawn again.
    public func resetLayout(in settings: any SettingsStore) {
        settings.set(nil as Data?, forKey: Self.settingsKey)
        onChange?()
    }

    deinit {
        // Nothing to release.
    }
}
