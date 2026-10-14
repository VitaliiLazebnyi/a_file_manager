@testable import ViewerPlugin

/// What the `rows` target compares of a row: everything the layout decided.
internal struct RowKey: Equatable {
    /// The bytes of the row.
    internal let range: Range<Int64>
    /// Where the row's content ends, before the line break.
    internal let contentEnd: Int64
    /// The text shown.
    internal let text: String
    /// The byte offset of every UTF-16 unit of the text, from the row's start.
    internal let offsets: [Int32]
    /// Whether the row starts a line.
    internal let startsLine: Bool
    /// The line the row belongs to, from 1.
    internal let line: Int

    /// The key of `row`.
    internal init(_ row: DisplayRow) {
        range = row.range
        contentEnd = row.contentEnd
        text = row.text
        offsets = row.offsets
        startsLine = row.startsLine
        line = row.line
    }
}
