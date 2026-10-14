import Foundation

/// What a file system can do, so commands can be offered or withheld before they fail.
public struct FileSystemCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Files and folders can be created, changed and deleted.
    public static let write = Self(rawValue: 1)
    /// Deleted items can go to a Trash.
    public static let trash = Self(rawValue: 2)
    /// An existing file can be opened to continue it (`append(to:at:cancellation:)`).
    public static let append = Self(rawValue: 4)
    /// What is written is kept back for a while (in memory, in a spool file) before it reaches
    /// its place for good. Whoever is about to destroy the only other copy of what it wrote
    /// calls `commit(_:cancellation:)` first. Without this, `commit` has nothing to do and
    /// need not be called.
    public static let deferredWrites = Self(rawValue: 8)
    /// Said besides `write` by a location whose entries can be deleted or changed while
    /// nothing can be created in it (a list of files gathered from elsewhere): commands
    /// that make something new there (Paste, New Folder, New File, a copy into it) are
    /// withheld, the others are offered.
    public static let removeOnly = Self(rawValue: 16)
}
