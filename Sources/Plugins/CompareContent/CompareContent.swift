public import Foundation

/// Two files as the compare window shows them.
public enum CompareContent: Sendable {
    /// Two files compared byte by byte, `diff` telling the rows that differ.
    case binary(left: Data, right: Data, diff: BinaryDiff)
    /// Nothing to show: nothing loaded yet, identical files, or files that could not be read.
    case empty
    /// Two texts laid side by side; `width` is the longest line in UTF-16 units, for the width of the panes.
    case text(left: TextDocument, right: TextDocument, diff: TextDiff, width: Int)

    /// Whether there is nothing to show.
    internal var isEmpty: Bool {
        if case .empty = self {
            return true
        }
        return false
    }
}
