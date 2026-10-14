public import Foundation

/// Where navigation leads, entering directories and going back to a snapshot.
extension PanelModel {
    /// The parent directory, and the name of the folder being left: the cursor lands on it.
    public var parentTarget: (location: URL, focus: String)? {
        parent.map { ($0, directory.lastPathComponent) }
    }

    /// The root directory, and the folder below it that was part of the old path.
    public var rootTarget: (location: URL, focus: String?)? {
        guard !root.isSameLocation(as: directory) else {
            return nil
        }
        let below = directory.pathComponents.dropFirst(root.pathComponents.count).first
        return (root, below)
    }

    /// Where Go Back leads; nil at the start of the history.
    public var backLocation: URL? { history.back }
    /// Where Go Forward leads; nil at the end of the history.
    public var forwardLocation: URL? { history.forward }

    /// The most recent place of the history before the current one that `isWanted` accepts
    /// (the folder the user came from before entering a volume that is about to go away).
    public func lastVisited(where isWanted: (URL) -> Bool) -> URL? {
        history.lastVisited(where: isWanted)
    }

    /// Goes back to what the panel showed when the snapshot was taken: the same entries through the
    /// same filter.
    ///
    /// The order is the panel's present one: if it was changed since, the list is put into it, so
    /// the order shown and the order named always agree (a sort on the calling thread, in that one
    /// case; otherwise this costs nothing).
    public func restore(_ snapshot: Snapshot) {
        keepSavedMarksByName()
        directory = snapshot.directory
        var lists = ArrangedLists(
            listed: snapshot.lists.lists[0],
            shown: snapshot.lists.lists[1],
            places: snapshot.places,
            index: snapshot.index,
            tally: nil,
            moves: .same
        )
        take(&lists)
        lists.discard()
        (cursor, marks, sized, filter) = (snapshot.cursor, snapshot.marks, snapshot.sized, snapshot.filter)
        counted.forget()
        arrangementChanged(list: true, index: snapshot.index)
        adopt(snapshot.surroundings)
        adopt(snapshot.state)
        (history, isInArrivalOrder) = (snapshot.history, snapshot.isInArrivalOrder)
        (isOpening, pendingFocus) = (false, nil)
        let wanted = requestedSort ?? sort
        requestedSort = nil
        sort = snapshot.sort
        if wanted != snapshot.sort {
            // Announces the change itself.
            _ = take(Self.prepare(Basis(self, discards: false), sort: wanted, indexing: false))
        } else {
            changed(.contents)
        }
    }

    /// Enters a directory at once, before anything of it has been read: the panel shows its path
    /// and an empty list (with `[..]`, so the way back is open), and the entries follow through
    /// `show` and `extend`.
    ///
    /// `parent` and `root` come from the file system's own arithmetic on the location, which needs
    /// no reading. If the reading fails, `restore` takes the panel back.
    public func open(_ directory: URL, parent: URL?, root: URL, history effect: HistoryEffect = .record) {
        keepSavedMarksByName()
        self.directory = directory.standardized
        adopt(Surroundings(parent: parent, root: root, volume: nil))
        var lists = ArrangedLists(listed: [], shown: [], places: nil, index: nil, tally: nil, moves: .same)
        take(&lists)
        lists.discard()
        (marks, sized, cursor) = (Bitset(), nil, 0)
        counted.forget()
        arrangementChanged(list: true, index: nil)
        adopt(ListState(isListed: false, isComplete: false, isRefreshing: false))
        (isOpening, pendingFocus) = (true, nil)
        isInArrivalOrder = true
        history.record(self.directory, effect)
        changed(.contents)
    }

    /// Takes where a directory lies.
    internal func adopt(_ surroundings: Surroundings) {
        (parent, root, volume) = (surroundings.parent, surroundings.root, surroundings.volume)
    }

    /// Takes how far the list is known.
    internal func adopt(_ state: ListState) {
        (isListed, isComplete, isRefreshing) = (state.isListed, state.isComplete, state.isRefreshing)
    }
}
