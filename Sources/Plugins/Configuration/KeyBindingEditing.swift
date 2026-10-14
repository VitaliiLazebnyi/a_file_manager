import AFMKernel
import Foundation

/// Which command ends up with which keys, worked out the way the kernel does it at start-up:
/// every command's default keys in registration order (a key stays with its first owner), then
/// the user's bindings by command name (a key given to a command is taken from its owner).
enum KeyMap {
    static func resolve(_ commands: [Command], overrides: [String: [String]]) -> [CommandID: [Shortcut]] {
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

/// The user's key bindings while they are being edited (spec 14 › Redefining hotkeys and
/// aliases). Nothing changes outside until `commit`. Main thread only.
///
/// Unlike Total Commander's dialog, this one knows every key of every command, so it can say
/// which command a key belongs to before it is taken away.
@MainActor
final class KeyBindingEditor {
    private var commands: [Command]
    private var stored: [String: [String]]
    /// The user's bindings as they will be stored: command name → shortcuts in text form.
    private(set) var overrides: [String: [String]]
    private var resolved: [CommandID: [Shortcut]] = [:]

    init(commands: [Command], overrides: [String: [String]]) {
        self.commands = commands
        stored = overrides
        self.overrides = overrides
        resolve()
    }

    convenience init(kernel: Kernel) {
        self.init(
            commands: kernel.commands.all,
            overrides: Self.storedOverrides(in: kernel))
    }

    /// Takes bindings that were stored elsewhere since this editor was made (the Start menu's
    /// keys, a command's shortcut field) as the base, and keeps what was edited here on top.
    func rebase(commands: [Command], overrides fresh: [String: [String]]) {
        var merged = fresh
        for name in Set(overrides.keys).union(stored.keys) where overrides[name] != stored[name] {
            merged[name] = overrides[name]
        }
        self.commands = commands
        stored = fresh
        overrides = merged
        resolve()
    }

    func rebase(kernel: Kernel) {
        rebase(commands: kernel.commands.all, overrides: Self.storedOverrides(in: kernel))
    }

    static func storedOverrides(in kernel: Kernel) -> [String: [String]] {
        kernel.settings.value([String: [String]].self, forKey: KeyBindings.settingsKey) ?? [:]
    }

    /// Forgets the bindings of commands that no longer exist (a deleted or renamed user command).
    func discardOverrides(where isDead: (String) -> Bool) {
        let before = overrides.count
        overrides = overrides.filter { !isDead($0.key) }
        if overrides.count != before { resolve() }
    }

    private func resolve() {
        resolved = KeyMap.resolve(commands, overrides: overrides)
    }

    var isChanged: Bool { overrides != stored }

    func shortcuts(for command: CommandID) -> [Shortcut] { resolved[command] ?? [] }

    /// The command that has the key now.
    func owner(of shortcut: Shortcut) -> CommandID? {
        resolved.first { $0.value.contains(shortcut) }?.key
    }

    /// Whether the command's keys are the user's choice rather than the defaults.
    func isCustomized(_ command: CommandID) -> Bool { overrides[command.rawValue] != nil }

    /// Gives the command exactly these keys. A key another command has is taken from it, and
    /// that is written down for the other command too, so the result is the same after a restart.
    func set(_ shortcuts: [Shortcut], for command: CommandID) {
        for shortcut in shortcuts {
            guard let owner = owner(of: shortcut), owner != command else { continue }
            overrides[owner.rawValue] = self.shortcuts(for: owner).filter { $0 != shortcut }.map(\.notation)
        }
        var unique: [Shortcut] = []
        for shortcut in shortcuts where !unique.contains(shortcut) { unique.append(shortcut) }
        overrides[command.rawValue] = unique.map(\.notation)
        resolve()
    }

    func add(_ shortcut: Shortcut, to command: CommandID) {
        set(shortcuts(for: command).filter { $0 != shortcut } + [shortcut], for: command)
    }

    /// Gives a key to a command the way the editors do: when another command has it, the user
    /// is told which one and decides. Returns false when the key stayed where it was.
    @discardableResult
    func assign(_ shortcut: Shortcut, to command: CommandID, adding: Bool, asking ui: any UserInteraction) -> Bool {
        if let owner = owner(of: shortcut), owner != command {
            let title = commands.first { $0.id == owner }?.title ?? owner.rawValue
            let answer = ui.choose(
                "\(ShortcutText.display(shortcut)) is already in use",
                detail: "It runs “\(title)” (\(owner.rawValue)). Give it to this command instead?",
                buttons: ["Reassign", "Cancel"], style: .warning)
            guard answer == 0 else { return false }
        }
        if adding {
            add(shortcut, to: command)
        } else {
            set([shortcut], for: command)
        }
        return true
    }

    /// Back to the keys the command's plugin proposed, as far as no other command of the
    /// user's own bindings holds them.
    func reset(_ command: CommandID) {
        overrides[command.rawValue] = nil
        resolve()
    }

    func resetAll() {
        overrides = [:]
        resolve()
    }

    /// Stores the bindings and applies them to the running program: every command is given
    /// its final keys, so the state is the one the next start arrives at.
    func commit(to settings: any SettingsStore, keyBindings: KeyBindings) {
        if overrides.isEmpty {
            settings.set(nil as Data?, forKey: KeyBindings.settingsKey)
        } else {
            settings.set(overrides, forKey: KeyBindings.settingsKey)
        }
        Self.apply(resolved, of: commands, to: keyBindings)
    }

    static func apply(_ keys: [CommandID: [Shortcut]], of commands: [Command], to keyBindings: KeyBindings) {
        var all: [String: [String]] = [:]
        for command in commands { all[command.id.rawValue] = (keys[command.id] ?? []).map(\.notation) }
        keyBindings.apply(overrides: all)
    }

    /// Brings the running program in line with the stored bindings, after they were replaced
    /// as a whole (import, reset).
    static func reapply(in kernel: Kernel) {
        let overrides = kernel.settings.value([String: [String]].self, forKey: KeyBindings.settingsKey) ?? [:]
        apply(
            KeyMap.resolve(kernel.commands.all, overrides: overrides), of: kernel.commands.all, to: kernel.keyBindings
        )
    }
}

/// Shortcuts as the user reads and presses them.
enum ShortcutText {
    private static let keyNames: [Key: String] = [
        .returnKey: "↩", .enter: "⌤", .tab: "⇥", .space: "Space", .backspace: "⌫", .forwardDelete: "⌦",
        .insert: "Insert",
        .home: "↖", .end: "↘", .pageUp: "⇞", .pageDown: "⇟", .left: "←", .right: "→", .up: "↑", .down: "↓",
        .keypadPlus: "Num +", .keypadMinus: "Num −", .keypadMultiply: "Num *", .keypadDivide: "Num /"
    ]

    /// The Mac's way of writing a shortcut: `⌃⌥⇧⌘C`, `⇧F5`.
    static func display(_ shortcut: Shortcut) -> String {
        var text = ""
        if shortcut.modifiers.contains(.control) { text += "⌃" }
        if shortcut.modifiers.contains(.option) { text += "⌥" }
        if shortcut.modifiers.contains(.shift) { text += "⇧" }
        if shortcut.modifiers.contains(.command) { text += "⌘" }
        switch shortcut.key {
        case .character(let character): return text + character.uppercased()
        case .function(let number): return text + "F\(number)"
        default: return text + (keyNames[shortcut.key] ?? "?")
        }
    }

    static func display(_ shortcuts: [Shortcut]) -> String {
        shortcuts.map(display).joined(separator: ", ")
    }

    /// Reads what the user typed into a shortcut field: the stored notation (`ctrl+shift+n`)
    /// or the Mac's symbols (`⌃⇧N`). Nil when it names no key.
    static func parse(_ text: String) -> Shortcut? {
        var rest = text.trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        var modifiers: KeyModifiers = []
        let symbols: [Character: KeyModifiers] = ["⌃": .control, "⌥": .option, "⇧": .shift, "⌘": .command]
        while rest.count > 1, let first = rest.first, let modifier = symbols[first] {
            modifiers.insert(modifier)
            rest.removeFirst()
        }
        if let named = keyNames.first(where: { $0.value.lowercased() == rest.lowercased() })?.key {
            return Shortcut(named, modifiers)
        }
        guard let shortcut = Shortcut(notation: rest) else { return nil }
        return Shortcut(shortcut.key, shortcut.modifiers.union(modifiers))
    }

    private static let namedKeyCodes: [UInt16: Key] = {
        var keys: [UInt16: Key] = [
            36: .returnKey, 76: .enter, 48: .tab, 49: .space, 51: .backspace, 117: .forwardDelete, 114: .insert,
            115: .home, 119: .end, 116: .pageUp, 121: .pageDown, 123: .left, 124: .right, 125: .down, 126: .up,
            69: .keypadPlus, 78: .keypadMinus, 67: .keypadMultiply, 75: .keypadDivide
        ]
        for (index, code) in [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111].enumerated() {
            keys[UInt16(code)] = .function(index + 1)
        }
        return keys
    }()

    /// The shortcut a key press stands for, by the rule the window shell matches key presses
    /// with: a named key by its key code, otherwise the character the key produces without
    /// its modifiers. Nil for a press that produces nothing.
    static func shortcut(keyCode: UInt16, characters: String?, modifiers: KeyModifiers) -> Shortcut? {
        if let key = namedKeyCodes[keyCode] { return Shortcut(key, modifiers) }
        guard let characters = characters?.lowercased(), !characters.isEmpty else { return nil }
        return Shortcut(.character(characters), modifiers)
    }
}

/// A command as the lists of the editors show it.
struct CommandRow: Equatable {
    let id: CommandID
    let title: String
    /// The command's keys, ready to show.
    let keys: String
    /// The menu the command is in, or one of the two groups below.
    let category: String

    static let userCategory = "User commands"
    static let otherCategory = "Not in a menu"
}

/// The command list of the *Choose command* dialog, the keyboard page and the keyboard help
/// (spec 14 › The Choose command dialog). The categories are the menus the commands are in,
/// since that is where the user knows them from.
enum CommandCatalog {
    static func rows(commands: [Command], menus: [MenuRegistry.Menu], shortcuts: (CommandID) -> [Shortcut])
        -> [CommandRow]
    {
        var menuOf: [CommandID: String] = [:]
        for menu in menus {
            for case let id? in menu.items where menuOf[id] == nil { menuOf[id] = menu.title }
        }
        return commands.map { command in
            let isUser = command.id.rawValue.hasPrefix(UserCommand.prefix)
            return CommandRow(
                id: command.id, title: command.title, keys: ShortcutText.display(shortcuts(command.id)),
                category: isUser ? CommandRow.userCategory : menuOf[command.id] ?? CommandRow.otherCategory)
        }
    }

    /// The categories in menu order, the two general groups last.
    static func categories(of rows: [CommandRow], menus: [MenuRegistry.Menu]) -> [String] {
        let present = Set(rows.map(\.category))
        return (menus.map(\.title) + [CommandRow.userCategory, CommandRow.otherCategory]).filter(present.contains)
    }

    /// The rows of a category (nil = all) that contain every word of the filter in their
    /// name, title or keys.
    static func filter(_ rows: [CommandRow], text: String, category: String? = nil) -> [CommandRow] {
        let words = text.lowercased().split(separator: " ")
        return rows.filter { row in
            guard category == nil || row.category == category else { return false }
            let haystack = (row.id.rawValue + " " + row.title + " " + row.keys).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    /// The keyboard help: every command that has a key, grouped by menu (spec 17 › Help,
    /// `cm_Keyboard`), generated from the bindings in force.
    static func shortcutSheet(_ rows: [CommandRow], menus: [MenuRegistry.Menu]) -> String {
        var text = ""
        for category in categories(of: rows, menus: menus) {
            let bound = rows.filter { $0.category == category && !$0.keys.isEmpty }
            guard !bound.isEmpty else { continue }
            text += category + "\n"
            for row in bound {
                text +=
                    "    " + row.keys.padding(toLength: max(22, row.keys.count + 2), withPad: " ", startingAt: 0)
                    + row.title.replacingOccurrences(of: "…", with: "") + "\n"
            }
            text += "\n"
        }
        return text
    }
}
