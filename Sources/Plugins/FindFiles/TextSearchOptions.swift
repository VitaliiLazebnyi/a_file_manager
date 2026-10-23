/// The check boxes under "Find text" (spec 09 › "Find text").
///
/// "Case sensitive" is a member of `SearchQuery`, where it has always been.
public struct TextSearchOptions: Codable, Equatable, Sendable {
    /// "Whole words only": the text is found only where no letter, digit or `_` is next to it.
    public var wholeWords: Bool
    /// The text is a regular expression, matched line by line.
    public var regex: Bool
    /// The text is a string of hex bytes, with quoted literal text in between: `"PK" 03 04`.
    public var hex: Bool
    /// Finds the files that do not contain the text.
    public var notContaining: Bool
    /// A file matches when the text is found in any of these.
    public var encodings: [TextEncoding]

    /// The options with the given boxes ticked; by default a plain text in UTF-8.
    public init(
        wholeWords: Bool = false,
        regex: Bool = false,
        hex: Bool = false,
        notContaining: Bool = false,
        encodings: [TextEncoding] = [.utf8]
    ) {
        self.wholeWords = wholeWords
        self.regex = regex
        self.hex = hex
        self.notContaining = notContaining
        self.encodings = encodings
    }
}
