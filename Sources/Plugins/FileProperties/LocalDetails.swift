import Foundation

/// What the Mac's own file system knows about an item beyond the provider interface: owner,
/// further dates, flags and the space it really takes.
internal struct LocalDetails: Equatable {
    /// The permission bits with set-user-ID, set-group-ID and sticky (`st_mode & 0o7777`).
    internal var mode: UInt16
    /// The number of the owning user.
    internal var ownerID: uid_t
    /// The number of the owning group.
    internal var groupID: gid_t
    /// When the item was made (`st_birthtimespec`).
    internal var created: Date
    /// When its contents last changed.
    internal var modified: Date
    /// When it was last read.
    internal var accessed: Date
    /// `st_flags`: `UF_HIDDEN`, `UF_IMMUTABLE` (Finder's Locked) and the rest.
    internal var flags: UInt32
    /// The bytes the item takes on its volume.
    internal var allocated: Int64
    /// How many hard links lead to it.
    internal var linkCount: Int

    /// Whether the hidden flag is set.
    internal var isHidden: Bool { flags & UInt32(UF_HIDDEN) != 0 }
    /// Whether Finder's Locked flag is set.
    internal var isLocked: Bool { flags & UInt32(UF_IMMUTABLE) != 0 }
}
