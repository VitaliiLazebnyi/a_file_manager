/// How text is cut into rows (spec 10 › Text).
///
/// With wrapping on, a row breaks at a word boundary after at most `columns` characters; with
/// wrapping off it is simply cut there (the specification's `UnwrapWidth`), so no row is ever
/// unbounded.
internal struct TextLayoutOptions: Equatable {
    /// The most columns a row takes (at least 1).
    internal var columns: Int
    /// Whether a row breaks after the last space that fits (else it is cut at `columns`).
    internal var wordWrap: Bool
    /// The columns from one tab stop to the next (at least 1).
    internal var tabWidth: Int

    /// Options with the values given, each at least 1.
    internal init(columns: Int, wordWrap: Bool, tabWidth: Int) {
        self.columns = max(1, columns)
        self.wordWrap = wordWrap
        self.tabWidth = max(1, tabWidth)
    }
}
