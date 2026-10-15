import Foundation

/// Showing directories that were read.
extension PanelModel {
    /// Shows a directory that was just read.
    ///
    /// The selection starts empty and the cursor goes to `focus`, or to the top. With `complete:
    /// false` this is only the first piece; more follow through `extend`, and `finishLoading` ends
    /// it. After `open`, `effect` is not applied again: the visit is already in the history.
    ///
    /// `presorted` names the order the listing's items are already in, when they were sorted in
    /// the background; they are then taken as they are if that is still the panel's order.
    public func show(
        _ listing: Listing,
        focus: String? = nil,
        history effect: HistoryEffect = .record,
        complete: Bool = true,
        presorted: ListOrder? = nil
    ) {
        // The list that arrives is taken in the order the user asked for, if one is waiting.
        if let requestedSort { adoptSort(requestedSort) }
        let visit = PanelVisit(listing: listing, focus: focus, history: effect, complete: complete, remembered: false)
        present(visit, lists: arrangement(of: listing.items, presorted: presorted))
    }

    /// Shows an earlier reading of a directory, kept in memory, while the directory is read afresh.
    ///
    /// The list can be used at once; until the fresh reading arrives through `update(with:)`,
    /// `isRefreshing` is true and `isComplete` false. Should the fresh reading fail, the caller
    /// goes back with `restore`.
    public func showRemembered(
        _ listing: Listing,
        focus: String? = nil,
        history effect: HistoryEffect = .record,
        presorted: ListOrder? = nil
    ) {
        if let requestedSort { adoptSort(requestedSort) }
        let visit = PanelVisit(listing: listing, focus: focus, history: effect, complete: false, remembered: true)
        present(visit, lists: arrangement(of: listing.items, presorted: presorted))
    }

    /// A directory that is arriving piece by piece has grown: `listed` is everything that has come
    /// so far, sorted by `order` in the background.
    ///
    /// The cursor stays on its item and the selection is kept. The list is taken as it is when that
    /// is still the panel's order, so the main thread does no sorting. What is left to it here
    /// grows with the list: the filter is asked about every entry, and the marked entries and the
    /// cursor's are found again by name. **Not for the main thread on long lists**:
    /// `prepare(_:extendingTo: sortedBy:)` does all of that in the background.
    public func extend(to listed: [FileItem], sortedBy order: ListOrder) {
        if let requestedSort { adoptSort(requestedSort) }
        let grown = order == sort ? listed : Sorter.sort(listed, by: sort)
        let (shown, places) = ListWork.arrange(grown, by: filter)
        var lists = ArrangedLists(listed: grown, shown: shown, places: places, index: nil, tally: nil)
        extend(&lists, moves: .byName)
    }

    /// The directory has arrived completely.
    public func finishLoading() {
        guard !isComplete else {
            return
        }
        adopt(ListState(isListed: isListed, isComplete: true, isRefreshing: false))
        (isOpening, pendingFocus) = (false, nil)
        changed(.contents)
    }

    /// Takes a fresh listing of the directory already shown and keeps the cursor item, the
    /// selection and calculated folder sizes.
    ///
    /// Returns false when nothing visible changed; a listing that holds the entries the panel has
    /// already leaves the list, and `listVersion`, as they are.
    ///
    /// The work is done here, on the calling thread: comparing the lists, and for a listing
    /// that differs, filtering it and finding the marked entries again. **Not for the main
    /// thread on long lists**: that is `prepare(_:update:focus:presorted:)` in the
    /// background and `apply` here.
    @discardableResult
    public func update(with listing: Listing, focus: String? = nil, presorted: ListOrder? = nil) -> Bool {
        let basis = Basis(self, discards: false)
        return take(Self.prepare(basis, update: listing, focus: focus, presorted: presorted, tabulating: false))
            == .changed
    }

    /// Enters a directory that was read, as `show` and `showRemembered` do, with `lists`, its
    /// entries in the panel's order and through its filter.
    internal func present(_ visit: PanelVisit, lists arranged: ArrangedLists) {
        // After `open` the history already holds this visit; the directory just read may still
        // differ from the one that was opened (the location of a file leads to its folder).
        let wasOpening = isOpening
        keepSavedMarksByName()
        adopt(visit.listing)
        adopt(ListState(isListed: true, isComplete: visit.complete, isRefreshing: visit.remembered))
        // More pieces follow only for a directory that is still arriving.
        pendingFocus = visit.complete || visit.remembered ? nil : visit.focus
        var lists = arranged
        let count = lists.listed.count
        take(&lists)
        lists.discard()
        (marks, sized) = (Bitset(size: count), nil)
        counted.setList(lists.tally)
        counted.selected = nil
        arrangementChanged(list: true, index: lists.index)
        isInArrivalOrder = sort.key == .unsorted
        cursor = visit.focus.flatMap(row(ofName:)) ?? 0
        if wasOpening {
            history.replaceCurrent(with: directory)
        } else {
            history.record(directory, visit.history)
        }
        changed(.contents)
    }

    /// The listing's items in the panel's order and through its filter.
    internal func arrangement(of listed: [FileItem], presorted: ListOrder?) -> ArrangedLists {
        let sorted = presorted == sort ? listed : Sorter.sort(listed, by: sort)
        let (shown, places) = ListWork.arrange(sorted, by: filter)
        return ArrangedLists(listed: sorted, shown: shown, places: places, index: nil, tally: nil)
    }

    /// Takes the grown list of a directory that is arriving piece by piece; `moves` says where
    /// the entries it had are in it.
    internal func extend(_ lists: inout ArrangedLists, moves: Moves) {
        let cursorName = cursorItem?.name
        let wasOnParentRow = cursorIsOnParentRow
        replace(&lists, moves: moves, keepsTotals: false, isNewReading: true)
        isInArrivalOrder = sort.key == .unsorted
        if let focus = pendingFocus, let row = row(ofName: focus) {
            // The item the panel was asked to show has arrived.
            cursor = row
            pendingFocus = nil
        } else if let cursorName, let row = row(ofName: cursorName) {
            cursor = row
        } else if !wasOnParentRow {
            cursor = min(cursor, max(rowCount - 1, 0))
        }
        changed(.contents)
    }

    /// Takes the directory and its surroundings from a listing: it has been read, all of it.
    internal func adopt(_ listing: Listing) {
        directory = listing.directory.standardized
        adopt(Surroundings(parent: listing.parent, root: listing.root, volume: listing.volume))
        adopt(ListState(isListed: true, isComplete: true, isRefreshing: false))
        (isOpening, pendingFocus) = (false, nil)
    }
}
