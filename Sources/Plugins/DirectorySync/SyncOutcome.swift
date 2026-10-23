public import Foundation

/// What a run of Synchronize did.
public struct SyncOutcome: Sendable {
    /// The files copied and folders created.
    public var copied = 0
    /// The items deleted.
    public var deleted = 0
    /// The items left out: kept on the user's wish, or failed.
    public var skipped = 0
    /// What failed, each with the item's path.
    public var errors: [String] = []
    /// Whether the run was cancelled before its end.
    public var wasCancelled = false
    /// What was written to a file system that keeps writes back could not be made durable: the
    /// run ended there, and nothing was deleted.
    public var commitFailed = false
    /// The folders whose contents changed, for refreshing the panels.
    public var changedDirectories: [URL] = []
}
