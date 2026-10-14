/// A rule that leaves entries out of a panel's list: a display filter of the Show menu or the quick
/// filter.
///
/// `matches` runs on the main thread, once per entry, and must not block; a filter that is handed
/// to `PanelModel.filtered` runs wherever that is called, on several threads at once.
public struct PanelFilter: Sendable {
    /// Shown to the user while the filter is on, e.g. `*.txt`.
    public let title: String
    /// Whether an entry is shown.
    public let matches: @Sendable (FileItem) -> Bool

    /// A filter with its title and its test.
    @preconcurrency
    public init(title: String, matches: @escaping @Sendable (FileItem) -> Bool) {
        self.title = title
        self.matches = matches
    }

    /// Files whose names match a file mask; folders always stay (spec 03 › Display filters).
    nonisolated public static func mask(_ text: String) -> Self {
        let mask = FileMask(text)
        return Self(title: text) { $0.isFolder || mask.matches($0.name) }
    }
}
