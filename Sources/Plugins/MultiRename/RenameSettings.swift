/// Everything the fields of the tool hold: what "Save settings" stores under a name
/// (spec 09 › Saved settings and persistence).
internal struct RenameSettings: Codable, Equatable {
    /// The settings of `<default>`: no change.
    internal static let unchanged = Self()

    /// The rename mask for the name.
    internal var nameMask = "[N]"
    /// The rename mask for the extension.
    internal var extensionMask = "[E]"
    /// "Search for" of Search & Replace.
    internal var search = ""
    /// "Replace with" of Search & Replace.
    internal var replacement = ""
    /// `^`: respect upper and lower case.
    internal var caseSensitive = false
    /// `1x`: replace only the first occurrence.
    internal var firstOnly = false
    /// `[E]`: also search the extension.
    internal var searchesExtension = true
    /// "RegEx": the search is a regular expression.
    internal var regularExpression = false
    /// Subst.: the whole name is replaced by the replacement, not just the matched part.
    internal var substitute = false
    /// The case conversion applied last.
    internal var letterCase = LetterCase.unchanged
    /// The counter `[C]`: start, step, digits.
    internal var counter = CounterDefinition()
}
