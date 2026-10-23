import AFMContracts
import Foundation

/// Why a copy was not made, and what the pane says about it.
extension TemporaryCopies {
    /// Why a copy was not made.
    internal enum Refusal: Error, Equatable {
        /// The cancellation flag was set: nothing is said.
        case cancelled
        /// The size of the file, and the most that is copied.
        case tooLarge(Int64, limit: Int64)
        /// The disk would be too full with the copy on it.
        case noRoom
        /// The file could not be read, or the copy could not be written.
        case unreadable

        /// Whether the copy was stopped rather than refused.
        internal var isCancelled: Bool { self == .cancelled }

        /// What the pane shows in place of the file; empty when it was cancelled.
        internal var message: String {
            switch self {
            case .cancelled:
                return ""

            case .tooLarge(let size, let limit):
                return "The file (\(Format.shortSize(size))) is too large to be copied from its file system for this "
                    + "mode (the limit is \(Format.shortSize(limit))). Choose a text mode (1, 2 or 3)."

            case .noRoom:
                return "There is not enough free space on the disk to copy the file for this mode."

            case .unreadable:
                return "The file cannot be shown in this mode."
            }
        }
    }
}
