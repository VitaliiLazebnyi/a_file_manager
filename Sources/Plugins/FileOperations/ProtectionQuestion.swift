public import AFMKernel

/// The second question about an item that is protected (07 › Read-only, hidden and system
/// targets; 07 › Delete › Questions).
///
/// On the Mac "read only" is a file nobody may write to, and "locked" a file with the Finder's
/// Locked flag, which only shows when the change is refused.
public struct ProtectionQuestion: Sendable {
    public enum Reason: Sendable {
        case readOnly, hidden, locked
        /// The item cannot go to the Trash (a network share or a disk without one); the
        /// question is whether to delete it for good instead.
        case noTrash
    }
    public enum Purpose: Sendable { case overwrite, delete, move }

    public let reason: Reason
    public let purpose: Purpose
    public let item: FileItem
}
