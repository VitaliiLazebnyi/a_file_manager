import Foundation

/// What a viewer is asked to show: a file on any file system, or a text that is not a file.
internal struct ViewerItem {
    /// Where the bytes come from.
    internal enum Source {
        /// A file, read through the provider of its file system.
        case file(URL)
        /// A text that is not a file (a report, a listing), shown as UTF-8.
        case text(String)
    }

    /// Where the bytes come from.
    internal let source: Source
    /// What the window title names: the path of a file, the name of a text.
    internal let title: String

    /// The file's URL; nil for a text.
    internal var url: URL? {
        if case .file(let url) = source {
            return url
        }
        return nil
    }
}
