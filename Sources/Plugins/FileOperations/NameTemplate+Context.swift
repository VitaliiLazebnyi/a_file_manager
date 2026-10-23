public import Foundation

/// What a template is expanded with, and how an expansion can fail.
extension NameTemplate {
    /// Everything a template may refer to, gathered when the dialog opens.
    public struct Context: Sendable {
        /// The item under the cursor: its name with extension; empty on `[..]`.
        public var cursorName = ""
        /// Whether the item under the cursor is a folder: then `[N]` is its whole name and `[E]` is empty.
        public var cursorIsFolder = false
        /// The size of the item under the cursor in bytes, for `[S]`.
        public var cursorSize: Int64 = 0
        /// The name of the folder the panel shows, for `[P]`.
        public var parentName = ""
        /// The name of the folder above the one the panel shows, for `[G]`.
        public var grandparentName = ""
        /// The moment the dialog was opened.
        public var now = Date()
        /// The calendar the date and time placeholders are read in.
        public var calendar = Calendar.current
        /// The text on the clipboard, for `[X]`; nil when it holds none.
        public var clipboard: String?
        /// The environment variables, for `[%VAR%]`.
        public var environment: [String: String] = ProcessInfo.processInfo.environment
        /// Whether a name is taken already, for the optional digit `[C]`.
        ///
        /// May touch a file system.
        public var exists: @Sendable (String) -> Bool = { _ in false }

        /// A context with nothing under the cursor, the moment now and no name taken.
        public init() {
            // Every field has its default.
        }
    }

    /// Why a template gives no names.
    public enum Failure: LocalizedError, Equatable {
        /// `[X]` was asked for, and the clipboard holds no text.
        case emptyClipboard
        /// Every number of the optional digit was taken, for the name given.
        case noFreeName(String)

        /// The message for the user.
        public var errorDescription: String? {
            switch self {
            case .emptyClipboard:
                return "The clipboard holds no text for [X]."

            case .noFreeName(let name):
                return "No free name was found for \(name)."
            }
        }
    }
}
