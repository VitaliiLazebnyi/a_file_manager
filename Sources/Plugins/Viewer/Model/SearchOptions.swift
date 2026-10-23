import Foundation

/// The switches of the Find dialog (spec 10 › Find dialog); all off by default.
internal struct SearchOptions: Equatable, Codable {
    /// Only whole words: a match must not be part of a longer word.
    internal var wholeWords = false
    /// Letters must match in case.
    internal var caseSensitive = false
    /// Search towards the start of the file.
    internal var backwards = false
    /// The text is a hex string of bytes (`00 FF 12`, `"PK"0102`).
    internal var hex = false
    /// The text is a regular expression.
    internal var regex = false
}
