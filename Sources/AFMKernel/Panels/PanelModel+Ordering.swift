/// The order and the filter of the list.
extension PanelModel {
    /// The order an arriving list should be in: the requested one, else the present one.
    ///
    /// Whoever sorts a listing in the background before handing it over sorts by this.
    public var wantedSort: ListOrder { requestedSort ?? sort }

    /// What `setFilter` shows of a list: the entries that pass `filter`, in the list's order.
    ///
    /// **For any thread**: a long list is filtered on all cores, so `filter.matches` is then called
    /// from several threads at once and must be a function of the entry alone.
    nonisolated public static func filtered(_ listed: [FileItem], by filter: PanelFilter?) -> [FileItem] {
        ListWork.arrange(listed, by: filter).shown
    }

    /// Notes the order the user asked for without putting the list into it: costs nothing, and
    /// nothing is announced.
    ///
    /// From then on every list that arrives (`show`, `update`, `extend` and their `prepare` forms)
    /// is taken in this order and makes it the panel's; and a `prepare(_:sort:)` for another order
    /// is refused by `apply` as stale. So a caller that sorts a long list in the background
    /// (`prepare(_:sort:)`, `apply`) calls this first: when the directory changes while the sort is
    /// made, the reading that arrives brings the wanted order with it, and the sort need not be
    /// raced against the readings again and again. A later request replaces an earlier one;
    /// `setSort` and a successful `apply` of the wanted order end it.
    public func requestSort(_ order: ListOrder) {
        requestedSort = order == sort ? nil : order
    }

    /// Sorts the list on the calling thread.
    ///
    /// Turning the direction of the same key round costs one pass; another key costs a sort. **Not
    /// for the main thread on long lists**: a caller with one sorts in the background,
    /// `prepare(_:sort:)`, then `apply`.
    ///
    /// Choosing `unsorted` after another key leaves the files as that key had them (see
    /// `isInArrivalOrder`).
    public func setSort(_ order: ListOrder) {
        requestedSort = nil
        _ = take(Self.prepare(Basis(self, discards: false), sort: order, indexing: false))
    }

    /// Shows only the entries that pass `filter`; nil shows all again.
    ///
    /// The cursor stays on its item when that is still shown, and items that are no longer shown
    /// lose their mark.
    ///
    /// A caller that knows the new filter lets through only what the present one does (a quick
    /// filter that was typed on) says `narrowing`: the shown items are then filtered, not all.
    ///
    /// The filter is asked about every entry here, on the calling thread (on all cores for
    /// a long list). **Not for the main thread on long lists**: `prepare(_:filter:)` in the
    /// background, then `apply`.
    public func setFilter(_ filter: PanelFilter?, narrowing: Bool = false) {
        let basis = Basis(self, discards: false)
        guard narrowing, let filter else {
            _ = take(Self.prepare(basis, filter: filter))
            return
        }
        let (shown, places) = ListWork.narrow(items, at: shownPlaces, by: filter)
        let lists = ArrangedLists(
            listed: listedItems,
            shown: shown,
            places: places,
            index: lookups.index,
            tally: ListWork.tally(shown),
            moves: .same
        )
        _ = take(Prepared(.filter, from: basis, lists: lists, sort: sort, filter: filter))
    }

    /// Takes what the file system now says about the volume (its free space has changed)
    /// without reading the directory again.
    public func setVolume(_ volume: VolumeInfo?) {
        guard volume != self.volume else {
            return
        }
        self.volume = volume
        changed(.contents)
    }

    /// Takes effect when the directory is read again.
    public func setShowHidden(_ show: Bool) {
        showHidden = show
    }

    /// Makes `order` the panel's, for a list that has just been taken in it.
    internal func adoptSort(_ order: ListOrder) {
        if order != sort {
            sort = order
            if order.key != .unsorted { isInArrivalOrder = false }
        }
        if requestedSort == order { requestedSort = nil }
    }
}
