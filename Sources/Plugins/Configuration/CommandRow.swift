import AFMKernel

/// A command as the lists of the editors show it.
internal struct CommandRow: Equatable {
    /// The category of the user's own commands (`em_…`).
    internal static let userCategory = "User commands"
    /// The category of the commands that are in no menu.
    internal static let otherCategory = "Not in a menu"

    /// The command's name, such as `cm_Copy`.
    internal let id: CommandID
    /// The command's title, as the menus show it.
    internal let title: String
    /// The command's keys, ready to show.
    internal let keys: String
    /// The menu the command is in, or one of the two groups below.
    internal let category: String
}
