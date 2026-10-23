import AFMKernel
import AFMShell
import AppKit

/// The rows of the result list, the lists kept of earlier searches, and the window's own views.
extension FindFilesWindowController {
    /// A line of the result list (spec 09 › Running a search and the result list).
    internal enum Row {
        /// `[6 files and 0 directories found]`, always the first line.
        case summary(String)
        /// A file or folder found.
        case item(FileItem)
        /// The dashed line between two groups of duplicates.
        case separator
    }

    /// What one search found; kept so `<` and `>` can step through the earlier ones.
    internal struct ResultSet {
        /// The rows, the summary first.
        internal var rows: [Row]
        /// The rows are groups of duplicates.
        internal var showsDuplicates: Bool
        /// The locations of the items in the rows, in list order.
        internal var urls: [URL]
        /// How many of the items are files.
        internal var files: Int
        /// How many of the items are folders.
        internal var directories: Int
    }

    /// A finished result list made off the main thread: the rows (the summary first, to be
    /// filled in), the locations of the items in them, and the counts.
    internal struct Built {
        /// The rows, the summary first.
        internal var rows: [Row]
        /// The locations of the items in the rows, in list order.
        internal var urls: [URL]
        /// How many of the items are files.
        internal var files: Int
        /// How many of the items are folders.
        internal var directories: Int
        /// The rows are groups of duplicates.
        internal var showsDuplicates: Bool

        /// The list of `items`, in their order.
        internal static func make(items: [FileItem]) -> Self {
            var lines: [Row] = [.summary("")]
            lines.reserveCapacity(items.count + 1)
            var folders = 0
            for item in items {
                lines.append(.item(item))
                if item.isDirectory {
                    folders += 1
                }
            }
            return Self(
                rows: lines,
                urls: items.map(\.url),
                files: items.count - folders,
                directories: folders,
                showsDuplicates: false
            )
        }

        /// The list of the groups of duplicates, a separator between two groups.
        internal static func make(groups: [[FileItem]]) -> Self {
            var built = make(items: [])
            for (index, group) in groups.enumerated() {
                if index > 0 {
                    built.rows.append(.separator)
                }
                for item in group {
                    built.rows.append(.item(item))
                    built.urls.append(item.url)
                    // Duplicates are files only.
                    built.files += 1
                }
            }
            built.showsDuplicates = true
            return built
        }
    }

    /// The result list, which hands its keys to the window first.
    internal final class ResultsTableView: NSTableView {
        /// Answers a key; true when it was used.
        internal var onKey: ((NSEvent) -> Bool)?

        /// A key the window does not use goes to the table as usual.
        override internal func keyDown(with event: NSEvent) {
            if onKey?(event) != true {
                super.keyDown(with: event)
            }
        }
    }

    /// F2 belongs to "Search in found files" wherever the keyboard is in the window.
    internal final class FindWindow: ToolWindow {
        /// Called for F2.
        internal var onF2: (() -> Void)?

        /// Takes F2 before anything else in the window.
        override internal func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.type == .keyDown, Shortcut.f(2).matches(event) {
                onF2?()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }

    /// How far the window goes; what tests make small.
    internal struct Limits {
        /// The most hits a search of the window lists.
        internal var results = FindFilesWindowController.resultLimit
        /// The most paths taken from Spotlight's answer.
        internal var spotlight = SpotlightSearch.resultLimit
        /// The earlier searches are kept as far as their rows are not more than this.
        internal var earlierRows = 200_000
    }
}
