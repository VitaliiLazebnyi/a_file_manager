/// What happens to a file whose name is taken at the target, for the whole job (spec 07 ›
/// Default overwrite mode).
///
/// The first nine are the spec's `CopyOverwriteDefault` list in its order; the tenth exists only in
/// the Overwrite dialog. The raw values are that order: settings store them and lists show `allCases`.
public enum OverwriteMode: Int, CaseIterable, Sendable {
    /// Every file whose name is taken is asked about.
    case ask = 0
    /// The copied file gets a new name and the target stays.
    case autoRenameCopied = 4
    /// The target gets a new name and the copied file takes its place.
    case autoRenameExisting = 5
    /// A larger file overwrites a smaller one; the others are skipped.
    case copyLarger = 6
    /// A smaller file overwrites a larger one; the others are skipped.
    case copySmaller = 7
    /// Every target is overwritten.
    case overwriteAll = 1
    /// A target older than the copied file is overwritten; the others are skipped.
    case overwriteOlder = 3
    /// A target older than the copied file or of the same age is overwritten; the others are skipped.
    case overwriteOlderOrSame = 9
    /// An older target is renamed to make room for the copied file; a newer one stays and the file is skipped.
    case renameOlderSkipNewer = 8
    /// Every file whose name is taken is skipped.
    case skipAll = 2

    /// Every mode in the order of the spec's list (the order of the raw values).
    public static let allCases: [Self] = [
        .ask, .overwriteAll, .skipAll, .overwriteOlder, .autoRenameCopied, .autoRenameExisting, .copyLarger,
        .copySmaller, .renameOlderSkipNewer, .overwriteOlderOrSame
    ]

    /// The mode's name in the Copy dialog and on the configuration page.
    public var title: String {
        switch self {
        case .ask:
            return "Ask user"

        case .overwriteAll:
            return "Overwrite all"

        case .skipAll:
            return "Skip all"

        case .overwriteOlder:
            return "Overwrite all older"

        case .autoRenameCopied:
            return "Auto-rename copied"

        case .autoRenameExisting:
            return "Auto-rename target files"

        case .copyLarger:
            return "Copy all larger files (overwrite smaller)"

        case .copySmaller:
            return "Copy all smaller files (overwrite larger)"

        case .renameOlderSkipNewer:
            return "Rename older target files, skip newer"

        case .overwriteOlderOrSame:
            return "Overwrite all older and of the same age"
        }
    }
}
