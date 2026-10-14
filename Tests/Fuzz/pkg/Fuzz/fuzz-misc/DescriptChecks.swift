/// What the descript.ion targets share: the cases once left out, and the switch that brings them back.
internal enum DescriptChecks {
    /// Whether the checks once left out are made.
    ///
    /// The first campaign left two known failures out unless FZ_DESCRIPT_ALL was set (a first name that
    /// reads like a byte-order mark, a separator joined to its neighbour). Both are fixed, so every check
    /// is always on.
    internal static let checksAll = true

    /// Text at the start of a first name that reads like a byte-order mark.
    internal static let marks = ["\u{FEFF}", "ÿþ", "þÿ", "ï»¿"]

    /// The characters that separate names, comments and lines.
    internal static let delimiters: Set<Unicode.Scalar> = [" ", "\"", "\r", "\n", "\\"]

    /// Whether a separator in the text forms one character with what stands next to it.
    internal static func isGlued(_ line: String) -> Bool {
        line.contains { character in
            character.unicodeScalars.count > 1 && character.unicodeScalars.contains(where: delimiters.contains)
        }
    }

    /// Whether a name begins with text that reads like a byte-order mark.
    internal static func readsLikeMark(_ name: String) -> Bool {
        marks.contains { name.hasPrefix($0) }
    }
}
