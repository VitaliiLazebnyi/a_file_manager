import Foundation

/// A place inside an archive: the archive file, on whatever file system it lives (the local
/// disk, a server, another archive), and the path inside it.
internal struct ArchiveLocation: Equatable {
    /// The archive file itself, as its own file system names it.
    internal let archive: URL
    /// The path inside, with `/` between the names and none at either end; empty for the
    /// archive's top folder.
    internal let innerPath: String

    /// Whether this is the archive's top folder.
    internal var isRoot: Bool { innerPath.isEmpty }
}
