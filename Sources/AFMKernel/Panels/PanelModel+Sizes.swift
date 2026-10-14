import Foundation

/// Calculated folder sizes and the status line's figures.
extension PanelModel {
    /// A calculated size meant for the entry at a place of the list.
    internal struct SizeTarget {
        /// The entry's place in the list.
        internal let place: Int
        /// The size.
        internal let size: Int64
    }

    /// The figures of the status line (03 › Status line).
    ///
    /// A folder counts with its calculated size, once it has one. The two halves are counted when
    /// they are asked for (a long list on all cores) and kept: the totals of the list until it
    /// changes, those of the selection until it does; a single mark set or taken away is added or
    /// subtracted without counting again, and marking everything or the opposite is worked out from
    /// the list's figures.
    public var totals: Totals {
        if counted.list == nil { counted.setList(ListWork.tally(items)) }
        if counted.selected == nil {
            let tally = marks.isEmpty ? Tally() : ListWork.tally(listedItems, at: marks)
            counted.selected = Totals(selected: Counts(tally))
        }
        let (list, selected) = (counted.list ?? Totals(), counted.selected ?? Totals())
        return Totals(
            selected: Counts(
                bytes: selected.selectedBytes,
                files: selected.selectedFiles,
                folders: selected.selectedFolders
            ),
            total: Counts(bytes: list.totalBytes, files: list.totalFiles, folders: list.totalFolders)
        )
    }

    /// Calculated folder sizes for entries of the list, by name, as `setComputedSizes` takes them.
    ///
    /// **For any thread.** The sizes are written into a copy of the list that is made here, so that
    /// `apply` only puts the copy in the list's place: for a caller whose list is held by somebody
    /// else as well (see `setComputedSizes`), who would otherwise pay for that copy on the main
    /// thread. A name stands for the entries written exactly like it, else for the entry whose name
    /// is its composed form.
    ///
    /// `apply` answers `.stale` when the list, the filter or the order changed since the
    /// basis was taken, **or another size was set**: the caller takes a new basis and
    /// prepares again. `.unchanged` when no name was found.
    nonisolated public static func prepare(_ basis: Basis, computedSizes sizes: [(name: String, size: Int64)])
        -> Prepared
    {
        let old = basis.listedItems
        let finder = NameFinder(old, index: basis.index)
        let targets = sizes.flatMap { name, size in
            places(named: name, in: finder).map { SizeTarget(place: $0, size: size) }
        }
        var known = basis.sized ?? ListWork.sized(old)
        guard !targets.isEmpty else {
            let lists = ArrangedLists(
                listed: [],
                shown: [],
                places: basis.places,
                index: finder.index,
                tally: nil,
                moves: .same
            )
            let kind = PreparedKind.sizes(sizeStamp: basis.sizeStamp, sized: known)
            return Prepared(kind, from: basis, lists: lists, sort: basis.sort, filter: basis.filter)
        }
        // The basis holds the list too, so the first write below makes the copy: here, not
        // on the main thread.
        var listed = old
        for target in targets {
            listed[target.place].computedSize = target.size
            known.insert(target.place)
        }
        var shown = listed
        if let places = basis.places {
            shown = basis.items
            for target in targets {
                if let row = places.row(ofPlace: target.place) { shown[row].computedSize = target.size }
            }
        }
        let lists = ArrangedLists(
            listed: listed,
            shown: shown,
            places: basis.places,
            index: finder.index,
            tally: ListWork.tally(shown),
            moves: .same
        )
        let kind = PreparedKind.sizes(sizeStamp: basis.sizeStamp, sized: known)
        return Prepared(kind, from: basis, lists: lists, sort: basis.sort, filter: basis.filter)
    }

    /// The places a name stands for in the list of `finder`: those written exactly like it,
    /// else those written like its composed form.
    nonisolated internal static func places(named name: String, in finder: NameFinder) -> [Int] {
        let found = finder.places(of: name)
        guard found.isEmpty else {
            return found
        }
        let composed = name.precomposedStringWithCanonicalMapping
        return ExactName.areSame(composed, name) ? [] : finder.places(of: composed)
    }

    /// Sets the calculated sizes of items, by their names as they are written, and announces it
    /// once.
    ///
    /// Of two names that read the same, each finds its own item; a name written differently from
    /// every item finds one that reads the same. The list is not another list for it (`listVersion`
    /// stays), and the time taken grows with the number of sizes, not with the length of the list,
    /// whether a filter is on or not.
    ///
    /// With one exception: while somebody else holds the list as well (a `basis` or a
    /// `snapshot` that is still alive, the listing cache, a closure that took `items`), the
    /// first size that is set makes the model's own copy of it, which for a million entries
    /// is some tens of milliseconds, once. A caller that sets sizes on such a list and must
    /// not hold up the main thread uses `prepare(_:computedSizes:)` and `apply`.
    public func setComputedSizes(_ sizes: [(name: String, size: Int64)]) {
        // Which entries are meant is settled first: looking a name up reads the lists that
        // are changed below.
        let targets = sizes.flatMap { name, size in
            sizePlaces(named: name).map { SizeTarget(place: $0, size: size) }
        }
        guard !targets.isEmpty else {
            return
        }
        var known = sizedPlaces()
        // Without a filter both lists are one piece of memory; it is changed once and
        // shared again instead of being copied for each.
        let isShared = shownPlaces == nil
        if isShared { items = [] }
        for target in targets {
            let item = listedItems[target.place]
            listedItems[target.place].computedSize = target.size
            known.insert(target.place)
            let shown = isShared ? target.place : shownIndex(ofPlace: target.place)
            if !isShared, let shown { items[shown].computedSize = target.size }
            if shown != nil, item.isFolder { count(target.size, replacing: item, at: target.place) }
        }
        if isShared { items = listedItems }
        sized = known
        sizeStamp += 1
        changed(.selection)
    }

    /// The places a name of `setComputedSizes` stands for: every entry written exactly like
    /// it, else the shown entry that reads the same.
    internal func sizePlaces(named name: String) -> [Int] {
        let exact = places(ofExactly: name)
        guard exact.isEmpty else {
            return exact
        }
        return alike(name).map { [place(ofShown: $0)] } ?? []
    }

    /// Moves the counted sums by the difference a shown folder's new size makes.
    internal func count(_ size: Int64, replacing item: FileItem, at place: Int) {
        let before = item.computedSize ?? 0
        let (difference, overflow) = size.subtractingReportingOverflow(before)
        guard !overflow, size >= 0, before >= 0 else {
            counted.forget()
            return
        }
        counted.list = counted.list.flatMap { $0.adding(bytes: difference, selected: false) }
        if marks.contains(place) {
            counted.selected = counted.selected.flatMap { $0.adding(bytes: difference, selected: true) }
        }
    }
}
