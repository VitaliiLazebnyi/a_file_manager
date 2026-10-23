import Foundation

/// The error for a list that is no longer kept.
extension VirtualFileSystem {
    /// A list is kept in memory only: after a restart, or when many newer ones were made, the
    /// location of an old one leads nowhere.
    internal struct ForgottenList: LocalizedError {
        /// The title the list was shown under.
        internal let title: String
        /// The message the user reads, naming the list.
        internal var errorDescription: String? { "The list “\(title)” is no longer available." }
    }
}
