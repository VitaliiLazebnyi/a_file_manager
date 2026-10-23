import Foundation

/// Why a comment could not be written to a folder's `descript.ion`.
internal enum CommentFileError: LocalizedError {
    /// The format has no way to write this name so that it reads back as the same name.
    case unnameable
    /// The comment file is there but cannot be read whole (no permission, too large, not
    /// decodable); writing it would lose the comments it holds.
    case unreadable

    /// The message the user sees.
    internal var errorDescription: String? {
        switch self {
        case .unreadable:
            return "The comment file descript.ion cannot be read completely, so it was left as it is. "
                + "Writing it now would lose its other comments."

        case .unnameable:
            return "A name with a line break, or with both a space and a quotation mark, cannot be written "
                + "to the comment file descript.ion."
        }
    }
}
