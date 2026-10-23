import AFMKernel

/// Which command ends up with which keys, worked out the way the kernel does it at start-up:
/// every command's default keys in registration order (a key stays with its first owner), then
/// the user's bindings by command name (a key given to a command is taken from its owner).
internal enum KeyMap {
    /// The keys of each command, from the commands' defaults in registration order and the
    /// user's bindings (command name → shortcuts in text form) on top.
    internal static func resolve(_ commands: [Command], overrides: [String: [String]]) -> [CommandID: [Shortcut]] {
        var owners: [Shortcut: CommandID] = [:]
        var keys: [CommandID: [Shortcut]] = [:]
        for command in commands {
            for shortcut in command.defaultShortcuts where owners[shortcut] == nil {
                owners[shortcut] = command.id
                keys[command.id, default: []].append(shortcut)
            }
        }
        for (name, notations) in overrides.sorted(by: { $0.key < $1.key }) {
            let command = CommandID(rawValue: name)
            for old in keys[command] ?? [] { owners[old] = nil }
            keys[command] = []
            for shortcut in notations.compactMap(Shortcut.init(notation:)) {
                if let owner = owners[shortcut] { keys[owner]?.removeAll { $0 == shortcut } }
                owners[shortcut] = command
                keys[command]?.append(shortcut)
            }
        }
        return keys
    }
}
