/// Putting new lists in place of the old ones, with what belongs to their entries.
extension PanelModel {
    /// A calculated size to be written into an entry of the list.
    internal struct SizeWrite {
        /// The entry's place in `listedItems`.
        internal let place: Int
        /// The size; nil takes it away.
        internal let size: Int64?
    }

    /// Puts lists in the place of the present ones, which `lists` holds in their stead
    /// afterwards, to look at and then to release in the background (`discard`).
    internal func take(_ lists: inout ArrangedLists) {
        swap(&listedItems, &lists.listed)
        swap(&items, &lists.shown)
        shownPlaces = lists.places
    }

    /// What was kept about the lists is no longer true; `list` when the entries or their
    /// order changed, and not only which of them are shown.
    internal func arrangementChanged(list: Bool, index: NameIndex?) {
        stamp += 1
        if list {
            listVersion += 1
            lookups = NameLookups(index: index)
        } else {
            lookups.shownChanged()
        }
    }

    /// The saved marks no longer go by places: the list they are places of is about to go.
    internal func keepSavedMarksByName() {
        guard case .places(let places) = saved else {
            return
        }
        if places.count <= 4_096 {
            var names = Set<ExactName>(minimumCapacity: places.count)
            for place in places { names.insert(ExactName(listedItems[place].name)) }
            saved = .names(names)
        } else {
            // Too many to make names of on the main thread: the list stays behind for them.
            saved = .remains(Remains(listedItems), places)
        }
    }

    /// The places whose entries have a calculated size.
    internal func sizedPlaces() -> Bitset {
        if let sized, sized.size == listedItems.count {
            return sized
        }
        let found = ListWork.sized(listedItems)
        sized = found
        return found
    }

    /// Where the entry at `place` of the list `old` is in the present one.
    ///
    /// `shift` carries the distance of the last entry found from one call to the next.
    internal func destination(of place: Int, in old: [FileItem], by moves: Moves, shift: inout Int) -> Int? {
        switch moves {
        case .same:
            return place

        case .table(let table):
            let found = table[place]
            return found == .max ? nil : Int(found)

        case .byName:
            guard let found = self.place(of: old[place], near: place + shift) else {
                return nil
            }
            shift = found - place
            return found
        }
    }

    /// The places of a set in the list `old`, moved to where their entries are now.
    internal func moved(_ bits: Bitset, from old: [FileItem], by moves: Moves) -> Bitset {
        if case .same = moves, bits.size == listedItems.count {
            return bits
        }
        var result = Bitset(size: listedItems.count)
        var shift = 0
        for place in bits {
            if let found = destination(of: place, in: old, by: moves, shift: &shift) { result.insert(found) }
        }
        return result
    }

    /// Takes a list in the place of the present one, of which it is another order or a later
    /// reading: the marks, the saved marks and the calculated sizes stay with their entries.
    ///
    /// A later reading (`isNewReading`) takes the sizes for its folders only. `keepsTotals` keeps
    /// the counted totals, for a list that holds the same entries.
    internal func replace(_ lists: inout ArrangedLists, keepsTotals: Bool, isNewReading: Bool) {
        let (oldMarks, oldSized, oldCounted) = (marks, sizedPlaces(), counted)
        take(&lists)
        // `lists` holds the old lists from here on, for as long as their entries are looked at.
        arrangementChanged(list: true, index: lists.index)
        let old = lists.listed
        let moves = movesFor(oldMarks.count + oldSized.count, from: old, by: lists.moves)
        var kept = moved(oldMarks, from: old, by: moves)
        if shownPlaces != nil, !kept.isEmpty { kept.formIntersection(shownBits()) }
        marks = kept
        if case .places(let places) = saved { saved = .places(moved(places, from: old, by: moves)) }
        let writes = carriedSizes(oldSized, from: old, by: moves, isNewReading: isNewReading)
        write(writes)
        if keepsTotals, writes.isEmpty {
            counted = oldCounted
        } else {
            counted.setList(writes.isEmpty ? lists.tally : nil)
            counted.selected = nil
        }
        lists.discard()
    }

    /// How `count` entries of the list `old` are found in the present one: very many are
    /// found all at once, on all cores, instead of one name after the other.
    internal func movesFor(_ count: Int, from old: [FileItem], by moves: Moves) -> Moves {
        guard case .byName = moves, count > Self.indexedAbove else {
            return moves
        }
        let finder = NameFinder(listedItems, index: lookups.index)
        let table = ListWork.moves(from: old, to: finder)
        lookups.index = finder.index
        return .table(table)
    }

    /// Calculated sizes the present list does not have (they were set while it was worked out, or
    /// it knows none), carried over from the list `old`; sets `sized` to the places that have a
    /// size.
    ///
    /// A later reading takes the sizes for its folders only.
    internal func carriedSizes(_ oldSized: Bitset, from old: [FileItem], by moves: Moves, isNewReading: Bool)
        -> [SizeWrite]
    {
        var newSized = Bitset(size: listedItems.count)
        var writes: [SizeWrite] = []
        var shift = 0
        for place in oldSized {
            guard let found = destination(of: place, in: old, by: moves, shift: &shift) else {
                continue
            }
            let size = old[place].computedSize
            if listedItems[found].computedSize != size {
                guard !isNewReading || listedItems[found].isFolder else {
                    continue
                }
                writes.append(SizeWrite(place: found, size: size))
            }
            if size != nil { newSized.insert(found) }
        }
        sized = newSized
        return writes
    }

    /// Writes calculated sizes into both lists.
    internal func write(_ writes: [SizeWrite]) {
        guard !writes.isEmpty else {
            return
        }
        // Without a filter both lists are one piece of memory; it is changed once and
        // shared again instead of being copied for each.
        let isShared = shownPlaces == nil
        if isShared { items = [] }
        for write in writes {
            listedItems[write.place].computedSize = write.size
            if !isShared, let shown = shownIndex(ofPlace: write.place) { items[shown].computedSize = write.size }
        }
        if isShared { items = listedItems }
    }
}
