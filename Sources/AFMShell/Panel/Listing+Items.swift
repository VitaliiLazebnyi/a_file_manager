import AFMKernel

/// A listing with other entries: the same folder put in another order, or only part of it.
extension Listing {
    /// This listing's folder and surroundings with `items` in place of its own.
    internal func with(items: [FileItem]) -> Self {
        Self(directory: directory, items: items, parent: parent, root: root, volume: volume)
    }
}
