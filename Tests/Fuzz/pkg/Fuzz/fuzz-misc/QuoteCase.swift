@testable import ConfigurationPlugin

/// One template expanded with one set of names, and what a program must receive from it.
internal struct QuoteCase {
    /// The template, as the user writes it.
    internal let template: String
    /// The template expanded with the names.
    internal let pieces: [ExpandedPiece]
    /// The same template expanded with tame names of the same number: its line must be the same.
    internal let tamePieces: [ExpandedPiece]
    /// Per argument, the acceptable values.
    internal let expected: [[String]]
    /// The template and the names, for a report.
    internal let detail: String
}
