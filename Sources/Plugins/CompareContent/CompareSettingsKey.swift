/// The settings keys of Compare by content, all below `compareContent.`.
internal enum CompareSettingsKey {
    /// The scope that holds every key below.
    internal static let scope = "compareContent"
    /// Whether lines that differ only in upper and lower case are equal (a flag).
    internal static let ignoreCase = "ignoreCase"
    /// Whether runs of spaces count as one (a flag).
    internal static let ignoreSpaces = "ignoreRepeatedSpaces"
    /// Whether the kind of line break is ignored (a flag).
    internal static let ignoreLineEndings = "ignoreLineEndings"
    /// Whether the two files are shown above each other instead of side by side (a flag).
    internal static let vertical = "vertical"
    /// The index into `bytesPerLineChoices` of the bytes shown per row in binary mode.
    internal static let bytesPerLine = "bytesPerLine"
    /// The name of the font of the panes; empty for the system's fixed-width font.
    internal static let fontName = "fontName"
    /// The size of the font of the panes in points, as text.
    internal static let fontSize = "fontSize"
    /// The bytes per row the user can choose from in binary mode.
    internal static let bytesPerLineChoices = [8, 16, 24, 32]
}
