@testable import ViewerPlugin

/// The rows of a document in one comparable value, for the tests that index a text in more than one way.
extension TextDocument {
    /// Every row of the document as one line of text: its byte range, whether it starts a line, its line and its text.
    ///
    /// Two documents with the same signature found the same rows; the tests compare the ways of indexing with it.
    internal func signature() throws -> [String] {
        try rows(from: 0, count: rowCount, cancellation: nil)
            .map { row in
                "\(row.range.lowerBound)-\(row.range.upperBound) \(row.startsLine) \(row.line) \(row.text)"
            }
    }
}
