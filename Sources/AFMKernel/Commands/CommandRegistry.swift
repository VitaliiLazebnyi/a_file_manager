import Foundation

/// The standard editing action a command shares its key with. The shell sends such a command
/// along the system's editing path, so text fields keep Cmd+C, Cmd+V, Cmd+X and Cmd+A.
public enum EditingRole {
    case cut, copy, paste, selectAll
}

/// What the user sees of a command.
public struct Command {
    public let id: CommandID
    public let title: String
    /// The keys the command has until the user chooses others (see `KeyBindings`).
    public let defaultShortcuts: [Shortcut]
    public let editingRole: EditingRole?
    /// The caption on the function-key bar, shown when the command is bound to a plain F-key.
    public let barLabel: String?
    /// Whether the command may run while a file job is in progress. Only commands that change
    /// neither files nor panels should say yes.
    public let runsDuringJobs: Bool

    public init(
        _ id: CommandID, _ title: String, _ defaultShortcuts: [Shortcut] = [], editingRole: EditingRole? = nil,
        barLabel: String? = nil, runsDuringJobs: Bool = false
    ) {
        self.id = id
        self.title = title
        self.defaultShortcuts = defaultShortcuts
        self.editingRole = editingRole
        self.barLabel = barLabel
        self.runsDuringJobs = runsDuringJobs
    }
}

/// The one place every command is registered and passes through, whatever triggered it: menu,
/// key, button, context menu or another plugin (spec 20 › Command dispatch contract).
/// Used on the main thread only.
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
        _ command: Command, enabled: @escaping () -> Bool = { true }, checked: @escaping () -> Bool = { false },
        parameterized run: @escaping (CommandArgument) -> Void
    ) {
        precondition(entries[command.id] == nil, "Command \(command.id) is registered twice")
        entries[command.id] = Entry(command: command, run: run, isEnabled: enabled, isChecked: checked)
        order.append(command.id)
        command.defaultShortcuts.forEach { keyBindings.bindDefault($0, to: command.id) }
    }

    public func register(
        _ command: Command, enabled: @escaping () -> Bool = { true }, checked: @escaping () -> Bool = { false },
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
