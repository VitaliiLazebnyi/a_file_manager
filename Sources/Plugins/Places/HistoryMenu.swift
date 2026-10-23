import AFMKernel
public import Foundation

/// The history pop-up as a list of rows: the panel's history, then the frequently used
/// folders (spec 03 › Directory history list).
public struct HistoryMenu {
    /// One line of the pop-up.
    public enum Row: Equatable {
        /// A directory of the panel's history.
        case visit(URL)
        /// The line between the history and the frequently used folders; it cannot be chosen.
        case separator
        /// One of the frequently used folders.
        case frequent(URL)

        /// The directory the row goes to; nil for the separator.
        public var directory: URL? {
            switch self {
            case .visit(let url), .frequent(let url):
                return url

            case .separator:
                return nil
            }
        }
    }

    /// The rows, top to bottom.
    public let rows: [Row]
    /// The text of each row, in the order of `rows`; the current directory is marked with an arrow.
    public let titles: [String]
    /// The row of the directory the panel shows.
    public let selected: Int

    /// The pop-up for `history` (last visited first) and the `frequent` folders with their visit counts.
    ///
    /// `current` is the directory the panel shows, `displayPath` writes a directory as the user sees it.
    public init(history: [URL], frequent: [(directory: URL, visits: Int)], current: URL, displayPath: (URL) -> String) {
        var lines = history.map(Row.visit)
        var texts = history.map { ($0.isSameLocation(as: current) ? "➤ " : "    ") + displayPath($0) }
        if !frequent.isEmpty {
            if !lines.isEmpty {
                lines.append(.separator)
                texts.append("──────  Frequently used  ──────")
            }
            lines += frequent.map { .frequent($0.directory) }
            texts += frequent.map { "    " + displayPath($0.directory) + "   (\($0.visits))" }
        }
        rows = lines
        titles = texts
        selected = history.firstIndex { $0.isSameLocation(as: current) } ?? 0
    }
}
