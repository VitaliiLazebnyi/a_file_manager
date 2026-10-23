public import Foundation

/// How a plan is carried out: the directions the user left on in the Synchronize dialog, and its boxes.
public struct SyncRunOptions: Sendable {
    /// The copies from the left to the right are made.
    public var copyToRight = true
    /// The copies from the right to the left are made.
    public var copyToLeft = true
    /// The deletions on the left are made.
    public var deleteLeft = true
    /// The deletions on the right are made.
    public var deleteRight = true
    /// Ask before a copy replaces an existing file.
    public var confirmOverwrites = true
    /// Deleted items go to the Trash where the file system has one.
    public var useTrash = true
    /// Asymmetric only: afterwards every empty directory below this one is deleted
    /// ("Right: Delete all empty directories").
    public var removeEmptyDirectoriesBelow: URL?
    /// When the target cannot keep a copied file's date, the source file gets the target's
    /// date instead, so the pair compares equal next time (spec 09 › Synchronizing with FTP).
    public var mayChangeSourceDates = true
    /// Dates this close need no correcting.
    public var toleranceSeconds = 3

    /// Every direction, with overwrites confirmed and deletions to the Trash.
    public init() {
        // Every option has its default.
    }
}
