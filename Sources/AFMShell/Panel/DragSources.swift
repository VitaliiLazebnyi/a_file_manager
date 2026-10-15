import AFMContracts
import AFMKernel
import Foundation

/// Where the sources of a drag are, worked out once: the places themselves and the folders
/// they lie in. Whether a drop on a folder is pointless is then a matter of looking up that
/// folder and the folders above it, however many items are dragged. May be made on any thread.
internal struct DragSources: Sendable {
    /// Whether nothing is dragged.
    internal let isEmpty: Bool
    private let places: Set<String>
    private let folders: Set<String>

    /// The places of `sources`.
    internal init(_ sources: [URL]) {
        isEmpty = sources.isEmpty
        var places = Set<String>(minimumCapacity: sources.count)
        var folders = Set<String>()
        for source in sources {
            let key = source.locationKey
            places.insert(key)
            folders.insert(Self.parent(of: key) ?? source.deletingLastPathComponent().locationKey)
        }
        (self.places, self.folders) = (places, folders)
    }

    /// The key of the folder a location lies in, from its key alone; nil at the top.
    private static func parent(of key: String) -> String? {
        guard let scheme = key.range(of: "://"), let pathStart = key[scheme.upperBound...].firstIndex(of: "/"),
            let slash = key.lastIndex(of: "/"), key.index(after: slash) < key.endIndex
        else {
            return nil
        }
        // The root keeps its slash; everything else loses the last part of its path.
        return String(slash == pathStart ? key[...slash] : key[..<slash])
    }

    /// Whether dropping the sources into `destination` makes no sense: nothing to drop, a
    /// folder into itself or into one of its own subfolders, or a move of items into the folder
    /// they are already in.
    internal func isPointless(_ kind: TransferKind, into destination: URL) -> Bool {
        if isEmpty {
            return true
        }
        // Into one of the sources, or into a folder below one.
        var key: String? = destination.locationKey
        while let current = key {
            if places.contains(current) {
                return true
            }
            key = Self.parent(of: current)
        }
        return kind == .move && folders.count == 1 && folders.contains(destination.locationKey)
    }
}
