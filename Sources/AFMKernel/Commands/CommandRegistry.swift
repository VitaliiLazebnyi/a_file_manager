import os

/// The one place every command is registered and passes through, whatever triggered it: menu, key, button, context menu
/// or another plugin (spec 20 › Command dispatch contract).
///
/// Used on the main thread only.
@preconcurrency
@MainActor
public final class CommandRegistry {
    /// A registered command with what it runs and how it answers whether it can.
    private struct Entry {
        let command: Command
        let run: (CommandArgument) -> Void
        let isEnabled: () -> Bool
        let isChecked: () -> Bool
    }

    private static let log = Log.logger("Kernel")
    /// While this returns true (a job is running, or the window does not exist yet) only
    /// commands marked `runsDuringJobs` start.
    public var isBlocked: () -> Bool = { false }
    /// Called when a command is asked for but cannot run; the shell beeps.
    public var onRejected: () -> Void = {
        // Nobody listens until the shell says it does.
    }
    private let keyBindings: KeyBindings
    private var entries: [CommandID: Entry] = [:]
    private var order: [CommandID] = []

    /// Every registered command, in registration order.
    public var all: [Command] { order.compactMap { entries[$0]?.command } }

    /// A registry whose commands bring their default keys to `keyBindings`.
    public init(keyBindings: KeyBindings = KeyBindings()) {
        self.keyBindings = keyBindings
    }

    /// Registers a command whose handler looks at its argument. `enabled` and `checked` are
    /// asked on the main thread whenever a menu or a button is drawn.
    public func register(
        _ command: Command,
        enabled: @escaping () -> Bool = { true },
        checked: @escaping () -> Bool = { false },
        parameterized run: @escaping (CommandArgument) -> Void
    ) {
        guard entries[command.id] == nil else {
            Self.log.fault("The command \(command.id, privacy: .public) is registered twice; the first stays")
            return
        }
        entries[command.id] = Entry(command: command, run: run, isEnabled: enabled, isChecked: checked)
        order.append(command.id)
        for shortcut in command.defaultShortcuts { keyBindings.bindDefault(shortcut, to: command.id) }
    }

    /// Registers a command whose handler takes no argument.
    public func register(
        _ command: Command,
        enabled: @escaping () -> Bool = { true },
        checked: @escaping () -> Bool = { false },
        _ run: @escaping () -> Void
    ) {
        register(command, enabled: enabled, checked: checked) { (_: CommandArgument) in run() }
    }

    /// Whether the command is registered and may run now: not blocked by a job, unless it
    /// runs during jobs, and enabled by its plugin.
    public func isEnabled(_ id: CommandID) -> Bool {
        guard let entry = entries[id], entry.command.runsDuringJobs || !isBlocked() else {
            return false
        }
        return entry.isEnabled()
    }

    /// Whether the command shows a check mark in its menu; false for an unknown command.
    public func isChecked(_ id: CommandID) -> Bool {
        entries[id]?.isChecked() ?? false
    }

    /// Runs the command; returns false (after `onRejected`) when it is not available right now.
    @discardableResult
    public func perform(_ id: CommandID, _ argument: CommandArgument = .nothing) -> Bool {
        guard isEnabled(id), let entry = entries[id] else {
            onRejected()
            return false
        }
        entry.run(argument)
        return true
    }

    /// The command registered under `id`; nil when there is none.
    public subscript(id: CommandID) -> Command? { entries[id]?.command }

    deinit {
        // Nothing to release.
    }
}
