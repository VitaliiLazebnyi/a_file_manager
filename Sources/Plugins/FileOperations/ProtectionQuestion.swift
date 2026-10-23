public import AFMKernel

/// The second question about an item that is protected (07 › Read-only, hidden and system
/// targets; 07 › Delete › Questions).
///
/// On the Mac "read only" is a file nobody may write to, and "locked" a file with the Finder's
/// Locked flag, which only shows when the change is refused.
public struct ProtectionQuestion: Sendable {
    /// Why the item is asked about.
    public enum Reason: Sendable {
        /// The item is hidden.
        case hidden
        /// The item carries the Finder's Locked flag (or another that refuses changes).
        case locked
        /// The item cannot go to the Trash (a network share or a disk without one); the
        /// question is whether to delete it for good instead.
        case noTrash
        /// Nobody may write to the item.
        case readOnly
    }

    /// What the job is about to do to the item.
    public enum Purpose: Sendable {
        /// Delete it.
        case delete
        /// Move it away.
        case move
        /// Write another file over it.
        case overwrite
    }

    /// Why the item is asked about.
    public let reason: Reason
    /// What the job is about to do to it.
    public let purpose: Purpose
    /// The item.
    public let item: FileItem
}
