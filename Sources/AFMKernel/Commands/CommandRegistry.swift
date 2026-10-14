import Foundation

/// The one place every command is registered and passes through, whatever triggered it: menu,
/// key, button, context menu or another plugin (spec 20 › Command dispatch contract).
/// Used on the main thread only.
@MainActor
public final class CommandRegistry {
    private struct Entry {
        let command: Command
        let run: (CommandArgument) -> Void
        let isEnabled: () -> Bool
        let isChecked: () -> Bool
    }

    private let keyBindings: KeyBindings
    private var entries: [CommandID: Entry] = [:]
    private var order: [CommandID] = []
    /// While this returns true (a job is running, or the window does not exist yet) only
    /// commands marked `runsDuringJobs` start.
    public var isBlocked: () -> Bool = { false }
    /// Called when a command is asked for but cannot run; the shell beeps.
    public var onRejected: () -> Void = {}

    public init(keyBindings: KeyBindings = KeyBindings()) {
        self.keyBindings = keyBindings
    }

    /// Registers a command whose handler looks at its argument.
    public func register(
        _ command: Command,
        enabled: @escaping () -> Bool = { true },
        checked: @escaping () -> Bool = { false },
        parameterized run: @escaping (CommandArgument) -> Void
    ) {
        precondition(entries[command.id] == nil, "Command \(command.id) is registered twice")
        entries[command.id] = Entry(command: command, run: run, isEnabled: enabled, isChecked: checked)
        order.append(command.id)
        command.defaultShortcuts.forEach { keyBindings.bindDefault($0, to: command.id) }
    }

    public func register(
        _ command: Command,
        enabled: @escaping () -> Bool = { true },
        checked: @escaping () -> Bool = { false },
        _ run: @escaping () -> Void
    ) {
        register(command, enabled: enabled, checked: checked, parameterized: { _ in run() })
    }

    /// Every registered command, in registration order.
    public var all: [Command] { order.compactMap { entries[$0]?.command } }

    public subscript(id: CommandID) -> Command? { entries[id]?.command }

    public func isEnabled(_ id: CommandID) -> Bool {
        guard let entry = entries[id], entry.command.runsDuringJobs || !isBlocked() else { return false }
        return entry.isEnabled()
    }

    public func isChecked(_ id: CommandID) -> Bool {
        entries[id]?.isChecked() ?? false
    }

    /// Runs the command; returns false (after `onRejected`) when it is not available right now.
    @discardableResult
    public func perform(_ id: CommandID, _ argument: CommandArgument = .none) -> Bool {
        guard isEnabled(id), let entry = entries[id] else {
            onRejected()
            return false
        }
        entry.run(argument)
        return true
    }
}
