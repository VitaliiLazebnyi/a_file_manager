import Foundation

/// Which key runs which command. Plugins supply defaults with their commands; the user's own
/// choices, kept in the settings, replace them. Every key press and every menu key is looked
/// up here, so a key is bound in exactly one place (spec 14 › Redefining hotkeys).
@MainActor
public final class KeyBindings {
    /// Settings key of the user's bindings: command name → shortcuts in text form.
    public nonisolated static let settingsKey = "keyBindings"

    private var commands: [Shortcut: CommandID] = [:]
    private var shortcuts: [CommandID: [Shortcut]] = [:]

    public init() {}

    /// Binds a command's default key. A key that is already taken stays with its command.
    public func bindDefault(_ shortcut: Shortcut, to command: CommandID) {
        guard commands[shortcut] == nil else { return }
        commands[shortcut] = command
        shortcuts[command, default: []].append(shortcut)
    }

    public func command(for shortcut: Shortcut) -> CommandID? {
        commands[shortcut]
    }

    /// The keys of a command; the first is its main key.
    public func shortcuts(for command: CommandID) -> [Shortcut] {
        shortcuts[command] ?? []
    }

    /// Replaces the keys of the named commands. A key given to a command is taken away from
    /// whichever command had it; unreadable shortcut texts are ignored.
    public func apply(overrides: [String: [String]]) {
        for (name, notations) in overrides.sorted(by: { $0.key < $1.key }) {
            let command = CommandID(rawValue: name)
            for old in shortcuts[command] ?? [] { commands[old] = nil }
            shortcuts[command] = []
            for shortcut in notations.compactMap(Shortcut.init(notation:)) {
                if let owner = commands[shortcut] { shortcuts[owner]?.removeAll { $0 == shortcut } }
                commands[shortcut] = command
                shortcuts[command]?.append(shortcut)
            }
        }
    }

    /// The user's bindings from the settings.
    public func load(from settings: any SettingsStore) {
        if let overrides = settings.value([String: [String]].self, forKey: Self.settingsKey) {
            apply(overrides: overrides)
        }
    }
}
