public import Foundation

/// The contents of one directory as read from its file system, with what a panel needs to know
/// about its surroundings.
///
/// Read in the background, then handed to the panel's model.
public struct Listing: Sendable {
    /// The directory that was read.
    public let directory: URL
    /// In file-system order; the model sorts them.
    public let items: [FileItem]
    /// The directory above; nil for a root.
    public let parent: URL?
    /// The top of the tree the directory belongs to.
    public let root: URL
    /// What the file system said about the volume; nil when it could not say.
    public let volume: VolumeInfo?

    /// A directory with its entries and surroundings.
    public init(directory: URL, items: [FileItem], parent: URL?, root: URL, volume: VolumeInfo? = nil) {
        self.directory = directory
        self.items = items
        self.parent = parent
        self.root = root
        self.volume = volume
    }
}
