/// What the user sees of a command.
public struct Command: Sendable {
    /// The name the command is registered and run under.
    public let id: CommandID
    /// What menus and buttons say, e.g. `Copy…`.
    public let title: String
    /// The keys the command has until the user chooses others (see `KeyBindings`).
    public let defaultShortcuts: [Shortcut]
    /// The standard editing action the command shares its key with (`editing(_:)`); nil for
    /// most commands.
    public private(set) var editingRole: EditingRole?
    /// The caption on the function-key bar, shown when the command is bound to a plain F-key.
    public let barLabel: String?
    /// Whether the command may run while a file job is in progress.
    ///
    /// Only commands that change neither files nor panels should say yes.
    public let runsDuringJobs: Bool

    /// A command called `title`, with its default keys.
    public init(
        _ id: CommandID,
        _ title: String,
        _ defaultShortcuts: [Shortcut] = [],
        barLabel: String? = nil,
        runsDuringJobs: Bool = false
    ) {
        self.id = id
        self.title = title
        self.defaultShortcuts = defaultShortcuts
        self.barLabel = barLabel
        self.runsDuringJobs = runsDuringJobs
    }

    /// The same command, sharing its key with the standard editing action `role` (nil: with
    /// none), so that text fields keep that key.
    public func editing(_ role: EditingRole?) -> Self {
        var command = self
        command.editingRole = role
        return command
    }
}
