/// Sort keys of the Show menu; raw values match `sortorder=` in the spec (03 › Sort keys).
public enum SortKey: Int, Sendable {
    /// Files by date, newest first to start with.
    case date = 3
    /// Files by extension, then by name.
    case ext = 1
    /// By name.
    case name = 0
    /// Files by size, largest first to start with.
    case size = 2
    /// Files in the order the file system gave them; folders by name.
    case unsorted = 4

    /// Time and Size start descending (newest / largest first), the others ascending.
    public var startsDescending: Bool { self == .date || self == .size }
}
