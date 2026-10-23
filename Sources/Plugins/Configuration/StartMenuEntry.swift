import AFMKernel

/// An entry of the Start menu (spec 14 › Start menu).
///
/// The n-th entry runs as `cm_UserMenu<n>`.
internal struct StartMenuEntry: Codable, Equatable {
    /// A line between two groups of entries.
    internal static let separator = Self(title: "-")

    /// A title of `-` makes a separator, as in Total Commander.
    internal var title: String
    /// What the entry does.
    internal var action = CommandAction()
    /// Whether the entry is a line between groups rather than something to choose.
    internal var isSeparator: Bool { title == "-" }

    /// The name of the command that runs the entry at `index` (counted from 0).
    internal static func commandID(at index: Int) -> CommandID { CommandID(rawValue: "cm_UserMenu\(index + 1)") }
}
