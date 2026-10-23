import AFMKernel
import Foundation

/// The user's key bindings while they are being edited (spec 14 › Redefining hotkeys and
/// aliases).
///
/// Nothing changes outside until `commit`. Main thread only.
///
/// Unlike Total Commander's dialog, this one knows every key of every command, so it can say
/// which command a key belongs to before it is taken away.
@MainActor
internal final class KeyBindingEditor {
    private var commands: [Command]
    private var stored: [String: [String]]
    /// The user's bindings as they will be stored: command name → shortcuts in text form.
    internal private(set) var overrides: [String: [String]]
    private var resolved: [CommandID: [Shortcut]] = [:]

    /// Whether the bindings differ from the stored ones.
    internal var isChanged: Bool { overrides != stored }

    /// An editor for these commands, starting from the stored bindings `overrides`.
    internal init(commands: [Command], overrides: [String: [String]]) {
        self.commands = commands
        stored = overrides
        self.overrides = overrides
        resolve()
    }

    /// An editor for the kernel's commands and the bindings its settings hold.
    internal convenience init(kernel: Kernel) {
        self.init(
            commands: kernel.commands.all,
            overrides: Self.storedOverrides(in: kernel)
        )
    }

    /// The user's bindings as the settings store holds them; empty when none are stored.
    internal static func storedOverrides(in kernel: Kernel) -> [String: [String]] {
        kernel.settings.value([String: [String]].self, forKey: KeyBindings.settingsKey) ?? [:]
    }

    /// Gives every command of `commands` exactly its keys in `keys` (none when it has no entry).
    internal static func apply(_ keys: [CommandID: [Shortcut]], of commands: [Command], to keyBindings: KeyBindings) {
        var all: [String: [String]] = [:]
        for command in commands { all[command.id.rawValue] = (keys[command.id] ?? []).map(\.notation) }
        keyBindings.apply(overrides: all)
    }

    /// Brings the running program in line with the stored bindings, after they were replaced
    /// as a whole (import, reset).
    internal static func reapply(in kernel: Kernel) {
        apply(
            KeyMap.resolve(kernel.commands.all, overrides: storedOverrides(in: kernel)),
            of: kernel.commands.all,
            to: kernel.keyBindings
        )
    }

    /// Takes bindings that were stored elsewhere since this editor was made (the Start menu's
    /// keys, a command's shortcut field) as the base, and keeps what was edited here on top.
    internal func rebase(commands: [Command], overrides fresh: [String: [String]]) {
        var merged = fresh
        for name in Set(overrides.keys).union(stored.keys) where overrides[name] != stored[name] {
            merged[name] = overrides[name]
        }
        self.commands = commands
        stored = fresh
        overrides = merged
        resolve()
    }

    /// Rebases on the kernel's commands and the bindings its settings hold now.
    internal func rebase(kernel: Kernel) {
        rebase(commands: kernel.commands.all, overrides: Self.storedOverrides(in: kernel))
    }

    /// Forgets the bindings of commands that no longer exist (a deleted or renamed user command).
    internal func discardOverrides(where isDead: (String) -> Bool) {
        let before = overrides.count
        overrides = overrides.filter { !isDead($0.key) }
        if overrides.count != before { resolve() }
    }

    private func resolve() {
        resolved = KeyMap.resolve(commands, overrides: overrides)
    }

    /// The keys the command has with the bindings as edited.
    internal func shortcuts(for command: CommandID) -> [Shortcut] { resolved[command] ?? [] }

    /// The command that has the key now.
    internal func owner(of shortcut: Shortcut) -> CommandID? {
        resolved.first { $0.value.contains(shortcut) }?.key
    }

    /// Whether the command's keys are the user's choice rather than the defaults.
    internal func isCustomized(_ command: CommandID) -> Bool { overrides[command.rawValue] != nil }

    /// Gives the command exactly these keys.
    ///
    /// A key another command has is taken from it, and that is written down for the other command
    /// too, so the result is the same after a restart.
    internal func set(_ shortcuts: [Shortcut], for command: CommandID) {
        for shortcut in shortcuts {
            guard let owner = owner(of: shortcut), owner != command else { continue }
            overrides[owner.rawValue] = self.shortcuts(for: owner).filter { $0 != shortcut }.map(\.notation)
        }
        var unique: [Shortcut] = []
        for shortcut in shortcuts where !unique.contains(shortcut) { unique.append(shortcut) }
        overrides[command.rawValue] = unique.map(\.notation)
        resolve()
    }

    /// Gives the command one key more (moved to the end when it has it already).
    internal func add(_ shortcut: Shortcut, to command: CommandID) {
        set(shortcuts(for: command).filter { $0 != shortcut } + [shortcut], for: command)
    }

    /// Gives a key to a command the way the editors do: when another command has it, the user
    /// is told which one and decides.
    ///
    /// Returns false when the key stayed where it was.
    @discardableResult
    internal func assign(
        _ shortcut: Shortcut,
        to command: CommandID,
        adding: Bool,
        asking interaction: any UserInteraction
    )
        -> Bool
    {
        if let owner = owner(of: shortcut), owner != command {
            let title = commands.first { $0.id == owner }?.title ?? owner.rawValue
            let answer = interaction.choose(
                "\(ShortcutText.display(shortcut)) is already in use",
                detail: "It runs “\(title)” (\(owner.rawValue)). Give it to this command instead?",
                buttons: ["Reassign", "Cancel"],
                style: .warning
            )
            guard answer == 0 else {
                return false
            }
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
    internal func reset(_ command: CommandID) {
        overrides[command.rawValue] = nil
        resolve()
    }

    /// Back to the default keys of every command.
    internal func resetAll() {
        overrides = [:]
        resolve()
    }

    /// Stores the bindings and applies them to the running program: every command is given
    /// its final keys, so the state is the one the next start arrives at.
    internal func commit(to settings: any SettingsStore, keyBindings: KeyBindings) {
        if overrides.isEmpty {
            settings.set(nil as Data?, forKey: KeyBindings.settingsKey)
        } else {
            settings.set(overrides, forKey: KeyBindings.settingsKey)
        }
        Self.apply(resolved, of: commands, to: keyBindings)
    }

    deinit {
        // Nothing to release.
    }
}
