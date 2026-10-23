/// The kinds of link Create Link makes (spec 07 › Create shortcut; a `.lnk` shortcut is a
/// symbolic link or a Finder alias on the Mac).
///
/// The raw value is the index the `fileProperties.linkKind` setting stores and the place in the
/// dialog's list, so `allCases` keeps that order.
internal enum LinkKind: Int, CaseIterable {
    /// A Finder alias, which finds its original again after a move.
    case alias = 1
    /// A hard link: another name of the same file.
    case hard = 2
    /// A symbolic link: a file that holds the path it leads to.
    case symbolic = 0

    /// The kinds in the order of their raw values, as the setting and the dialog number them.
    internal static let allCases: [Self] = [.symbolic, .alias, .hard]

    /// The name the dialog and the settings show.
    internal var title: String {
        switch self {
        case .symbolic:
            return "Symbolic link"

        case .alias:
            return "Finder alias"

        case .hard:
            return "Hard link"
        }
    }
}
