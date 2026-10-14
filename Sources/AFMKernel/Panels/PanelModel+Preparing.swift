/// Changes of the list worked out on any thread.
extension PanelModel {
    /// The list in another order.
    ///
    /// **For any thread.** Turning the direction round is one pass; anything else is a sort on all
    /// cores.
    nonisolated public static func prepare(_ basis: Basis, sort order: ListOrder) -> Prepared {
        prepare(basis, sort: order, indexing: true)
    }

    /// The list through another filter; nil shows everything.
    ///
    /// **For any thread**: a long list is filtered on all cores, so `filter.matches` is called from
    /// several threads at once and must be a function of the entry alone.
    nonisolated public static func prepare(_ basis: Basis, filter: PanelFilter?) -> Prepared {
        let (shown, places) = ListWork.arrange(basis.listedItems, by: filter)
        let lists = ArrangedLists(
            listed: basis.listedItems,
            shown: shown,
            places: places,
            index: basis.index,
            tally: ListWork.tally(shown)
        )
        return Prepared(.filter, from: basis, lists: lists, sort: basis.sort, filter: filter)
    }

    /// A fresh listing of the directory the panel shows, as `update(with:focus:presorted:)` takes
    /// it.
    ///
    /// **For any thread.** Everything that grows with the list is done here: sorting (unless
    /// `presorted` is the panel's order), comparing with what the panel has, carrying over
    /// calculated folder sizes, filtering, and finding the place every old entry has in the new
    /// list, so that `apply` only moves the marks.
    nonisolated public static func prepare(
        _ basis: Basis,
        update listing: Listing,
        focus: String? = nil,
        presorted: ListOrder? = nil
    ) -> Prepared {
        prepare(basis, update: listing, focus: focus, presorted: presorted, tabulating: true)
    }

    /// Entering a directory that was read, as `show(_:focus:history:complete:presorted:)` enters
    /// it.
    ///
    /// **For any thread.** Everything that grows with the list is done here: sorting (unless
    /// `presorted` is the order a list that arrives is put into), the filter over every entry, the
    /// index of names the cursor is found by, and the totals; `apply` then puts the lists in place,
    /// moves the cursor to `focus` and records the visit.
    ///
    /// `apply` answers `.stale` when the panel's list, filter or order changed since the
    /// basis was taken (the folder it showed was read again, another order was chosen):
    /// the caller takes a new basis and prepares again, in the background.
    nonisolated public static func prepare(
        _ basis: Basis,
        show listing: Listing,
        focus: String? = nil,
        history: HistoryEffect = .record,
        presorted: ListOrder? = nil
    ) -> Prepared {
        let visit = PanelVisit(listing: listing, focus: focus, history: history, complete: true, remembered: false)
        return prepare(basis, visit: visit, presorted: presorted)
    }

    /// Entering an earlier reading of a directory, kept in memory, as `showRemembered` enters it,
    /// while the directory is read afresh.
    ///
    /// **For any thread**, like `prepare(_:show:focus:history:presorted:)`.
    nonisolated public static func prepare(
        _ basis: Basis,
        showRemembered listing: Listing,
        focus: String? = nil,
        history: HistoryEffect = .record,
        presorted: ListOrder? = nil
    ) -> Prepared {
        let visit = PanelVisit(listing: listing, focus: focus, history: history, complete: false, remembered: true)
        return prepare(basis, visit: visit, presorted: presorted)
    }

    /// A directory that is arriving piece by piece, grown to `listed` (sorted by `order`), as
    /// `extend(to:sortedBy:)` takes it.
    ///
    /// **For any thread.**
    nonisolated public static func prepare(_ basis: Basis, extendingTo listed: [FileItem], sortedBy order: ListOrder)
        -> Prepared
    {
        let wanted = basis.wantedSort
        let grown = order == wanted ? listed : Sorter.sort(listed, by: wanted)
        let finder = NameFinder(grown)
        let table = ListWork.moves(from: basis.listedItems, to: finder)
        let (shown, places) = ListWork.arrange(grown, by: basis.filter)
        let lists = ArrangedLists(
            listed: grown,
            shown: shown,
            places: places,
            index: finder.index,
            tally: ListWork.tally(shown)
        )
        return Prepared(.extend(.table(table)), from: basis, lists: lists, sort: wanted, filter: basis.filter)
    }

    /// The list in another order; `indexing` makes the index of names of a long list along with it.
    ///
    /// For any thread.
    nonisolated internal static func prepare(_ basis: Basis, sort order: ListOrder, indexing: Bool) -> Prepared {
        let old = basis.listedItems
        // The list is in the order of its basis: asked for that order again, it stays.
        let indexes = order == basis.sort ? [] : Sorter.resortedIndexes(of: old, from: basis.sort, to: order)
        guard !indexes.isEmpty else {
            let lists = ArrangedLists(
                listed: old,
                shown: basis.items,
                places: basis.places,
                index: basis.index,
                tally: nil
            )
            return Prepared(.sortName, from: basis, lists: lists, sort: order, filter: basis.filter)
        }
        let listed = Sorter.permute(old, by: indexes)
        let table = ListWork.inverse(of: indexes)
        // What was shown is shown: the filter is not asked again.
        var (shown, places) = (listed, ShownPlaces?.none)
        if let oldPlaces = basis.places {
            let isShown = oldPlaces.bits(size: old.count)
            let kept = indexes.indices.filter { isShown.contains(Int(indexes[$0])) }.map { UInt32($0) }
            (shown, places) = (ListWork.picked(listed, at: kept), ShownPlaces(kept))
        }
        let index =
            basis.index.map { $0.moved(by: table) }
            ?? (indexing && listed.count > indexedAbove ? NameIndex(listed) : nil)
        let lists = ArrangedLists(
            listed: listed,
            shown: shown,
            places: places,
            index: index,
            tally: nil
        )
        return Prepared(.sort(table), from: basis, lists: lists, sort: order, filter: basis.filter)
    }

    /// A fresh listing of the directory the panel shows; with `tabulating`, the place of every old
    /// entry in the new list is found here as well.
    ///
    /// For any thread.
    nonisolated internal static func prepare(
        _ basis: Basis,
        update listing: Listing,
        focus: String?,
        presorted: ListOrder?,
        tabulating: Bool
    ) -> Prepared {
        guard listing.directory.isSameLocation(as: basis.directory) else {
            let visit = PanelVisit(listing: listing, focus: focus, history: .keep, complete: true, remembered: false)
            return prepare(basis, visit: visit, presorted: presorted, indexing: tabulating)
        }
        // A list that arrives is put into the order the user asked for, if one is waiting.
        let order = basis.wantedSort
        var listed = presorted == order ? listing.items : Sorter.sort(listing.items, by: order)
        let old = basis.listedItems
        if order == basis.sort, ListWork.areSameEntries(listed, old) {
            let lists = ArrangedLists(
                listed: old,
                shown: basis.items,
                places: basis.places,
                index: basis.index,
                tally: nil
            )
            let kind = PreparedKind.sameEntries(Reading(listing: listing, focus: focus))
            return Prepared(kind, from: basis, lists: lists, sort: basis.sort, filter: basis.filter)
        }
        let finder = NameFinder(listed)
        carrySizes(from: basis, into: &listed, finder: finder)
        let moves = tabulating ? Moves.table(ListWork.moves(from: old, to: finder)) : .byName
        let (shown, places) = ListWork.arrange(listed, by: basis.filter)
        let lists = ArrangedLists(
            listed: listed,
            shown: shown,
            places: places,
            index: finder.index,
            tally: ListWork.tally(shown)
        )
        let kind = PreparedKind.update(Reading(listing: listing, focus: focus), moves)
        return Prepared(kind, from: basis, lists: lists, sort: order, filter: basis.filter)
    }

    /// Entering a directory, as `show` and `showRemembered` do.
    ///
    /// For any thread.
    nonisolated internal static func prepare(_ basis: Basis, visit: PanelVisit, presorted: ListOrder?) -> Prepared {
        prepare(basis, visit: visit, presorted: presorted, indexing: true)
    }

    /// Entering a directory; `indexing` makes the index of names of a long list along with it.
    ///
    /// For any thread.
    nonisolated internal static func prepare(
        _ basis: Basis,
        visit: PanelVisit,
        presorted: ListOrder?,
        indexing: Bool
    ) -> Prepared {
        let order = basis.wantedSort
        let listed = presorted == order ? visit.listing.items : Sorter.sort(visit.listing.items, by: order)
        let (shown, places) = ListWork.arrange(listed, by: basis.filter)
        let lists = ArrangedLists(
            listed: listed,
            shown: shown,
            places: places,
            index: indexing && listed.count > indexedAbove ? NameIndex(listed) : nil,
            tally: ListWork.tally(shown)
        )
        return Prepared(.show(visit), from: basis, lists: lists, sort: order, filter: basis.filter)
    }

    /// Folder sizes calculated with Space, carried over from the basis's list to the same
    /// folders in a fresh reading of it.
    nonisolated internal static func carrySizes(from basis: Basis, into listed: inout [FileItem], finder: NameFinder) {
        let old = basis.listedItems
        var writes: [SizeWrite] = []
        var shift = 0
        for place in basis.sized ?? ListWork.sized(old) {
            guard let found = finder.place(of: old[place], near: place + shift) else {
                continue
            }
            shift = found - place
            if listed[found].isFolder { writes.append(SizeWrite(place: found, size: old[place].computedSize)) }
        }
        for write in writes { listed[write.place].computedSize = write.size }
    }
}
