/// What the comparison found out about a row (spec 09 › Comparison algorithm).
public enum SyncState: Equatable, Sendable {
    /// Both exist and differ, with no hint which one to keep.
    case different
    /// Both exist and are the same, by size and date or by content.
    case equal
    /// Never synchronized: the names differ only in case, or a file faces a folder.
    case excluded
    /// Both exist, and the left one is newer.
    case leftNewer
    /// Only the left side has it.
    case leftOnly
    /// A pair that should have been compared by content and was not (cancelled, unreadable).
    case pending
    /// Both exist, and the right one is newer.
    case rightNewer
    /// Only the right side has it.
    case rightOnly
}
