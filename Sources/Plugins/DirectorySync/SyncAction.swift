/// What Synchronize will do with a row.
public enum SyncAction: Equatable, Sendable {
    /// The right one is copied over to the left.
    case copyToLeft
    /// The left one is copied over to the right.
    case copyToRight
    /// Both are deleted.
    case deleteBoth
    /// The left one is deleted.
    case deleteLeft
    /// The right one is deleted.
    case deleteRight
    /// The row is left as it is.
    case nothing

    /// The symbol of the middle column (spec 09 › Result list).
    public var symbol: String {
        switch self {
        case .nothing:
            return ""

        case .copyToRight:
            return "→"

        case .copyToLeft:
            return "←"

        case .deleteLeft:
            return "✕←"

        case .deleteRight:
            return "→✕"

        case .deleteBoth:
            return "✕✕"
        }
    }
}
