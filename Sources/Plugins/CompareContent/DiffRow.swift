/// One line of the two panes: a line of the left file, of the right file, or of both.
public struct DiffRow: Equatable, Sendable {
    /// How the two sides of a row compare.
    public enum Kind: Equatable, Sendable {
        /// Both sides have a line here and the two are equal.
        case equal
        /// Both sides have a line here and the two differ.
        case changed
        /// Only the right side has a line here.
        case added
        /// Only the left side has a line here.
        case removed
    }

    /// The position of the row's line in the lines of the left file; nil where it has none.
    public let left: Int?
    /// The position of the row's line in the lines of the right file; nil where it has none.
    public let right: Int?
    /// How the two sides compare.
    public let kind: Kind
}
