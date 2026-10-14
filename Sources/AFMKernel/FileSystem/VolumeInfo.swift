/// What the status line shows of the volume a panel is on: its name and space.
public struct VolumeInfo: Equatable, Sendable {
    /// The volume's name, as the Finder shows it.
    public let name: String
    /// The bytes still free for the user; nil where the file system cannot say.
    public let freeBytes: Int64?
    /// The size of the whole volume in bytes; nil where the file system cannot say.
    public let totalBytes: Int64?
    /// False for network shares and other places where every question about a file travels:
    /// the panel then avoids anything that would ask about files one by one.
    public let isLocal: Bool

    /// A volume called `name`; a local one with no figures unless they are given.
    public init(name: String, freeBytes: Int64? = nil, totalBytes: Int64? = nil, isLocal: Bool = true) {
        self.name = name
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
        self.isLocal = isLocal
    }
}
