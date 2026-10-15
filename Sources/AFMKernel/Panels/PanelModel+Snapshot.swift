public import Foundation

/// What a panel shows, kept to go back to.
extension PanelModel {
    /// Everything a panel shows, kept so that a directory change that fails can be taken
    /// back: the lists with the filter they were shown through and the order they are in.
    public struct Snapshot: Sendable {
        /// The filter the panel showed its list through.
        ///
        /// Whoever keeps a filter of its own beside the model's (the text of a quick filter) puts
        /// it back along with `restore`.
        public let filter: PanelFilter?
        /// The order the lists are in.
        public let sort: ListOrder
        /// The directory that was shown.
        internal let directory: URL
        /// The listed and the shown items; released in the background when the snapshot goes.
        internal let lists: Remains
        /// Which entries were shown; nil when all were.
        internal let places: ShownPlaces?
        /// The index of the names, if the model had made one.
        internal let index: NameIndex?
        /// The row of the cursor.
        internal let cursor: Int
        /// The marked places.
        internal let marks: Bitset
        /// The places with a calculated size, if the model knew them.
        internal let sized: Bitset?
        /// The directory above, the top of the tree and the volume.
        internal let surroundings: Surroundings
        /// `isListed`, `isComplete` and `isRefreshing`.
        internal let state: ListState
        /// The visited directories.
        internal let history: PanelHistory
        /// The model's `isInArrivalOrder`.
        internal let isInArrivalOrder: Bool
    }

    /// Where a directory lies: what a listing says about its surroundings.
    internal struct Surroundings: Sendable {
        /// The directory above; nil for a root.
        internal let parent: URL?
        /// The top of the tree.
        internal let root: URL
        /// The volume, as the file system described it.
        internal let volume: VolumeInfo?
    }

    /// How far the list of a directory is known.
    internal struct ListState: Sendable {
        /// The directory was read at least once.
        internal let isListed: Bool
        /// The list is all there is.
        internal let isComplete: Bool
        /// The list is an earlier reading, and a fresh one is under way.
        internal let isRefreshing: Bool
    }

    /// What the panel shows now, to go back to with `restore`.
    public func snapshot() -> Snapshot {
        Snapshot(
            filter: filter,
            sort: sort,
            directory: directory,
            lists: Remains(listedItems, items),
            places: shownPlaces,
            index: lookups.index,
            cursor: cursor,
            marks: marks,
            sized: sized,
            surroundings: Surroundings(parent: parent, root: root, volume: volume),
            state: ListState(isListed: isListed, isComplete: isComplete, isRefreshing: isRefreshing),
            history: history,
            isInArrivalOrder: isInArrivalOrder
        )
    }
}
