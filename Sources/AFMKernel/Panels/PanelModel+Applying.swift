/// Taking changes that were worked out in the background.
extension PanelModel {
    /// Takes a prepared change, if the model's list, filter and order are still what they were when
    /// its basis was taken; otherwise nothing happens and the answer is `.stale`: the caller starts
    /// again from a new basis, in the background.
    ///
    /// Marks, the cursor and calculated sizes that changed in the meantime are not in the way; they
    /// are taken as they are now. A prepared change is applied once.
    @discardableResult
    public func apply(_ prepared: Prepared) -> Outcome {
        MainActor.assertIsolated()
        return take(prepared)
    }

    /// Takes a prepared change, as `apply` does.
    internal func take(_ prepared: Prepared) -> Outcome {
        guard prepared.stamp == stamp else {
            return .stale
        }
        switch prepared.kind {
        case .show(let visit):
            return takeShow(prepared, visit)

        case .sort(let table):
            return takeSort(prepared, table: table)

        case .sortName:
            return takeSortName(prepared)

        case .filter:
            return takeFilter(prepared)

        case .update(let reading, let moves):
            return takeUpdate(prepared, reading, moves: moves)

        case .sameEntries(let reading):
            return takeUpdate(prepared, reading, moves: nil)

        case .extend(let moves):
            adoptSort(prepared.sort)
            extend(&prepared.lists, moves: moves)
            return .changed

        case .sizes(let sizeStamp, let sized):
            guard sizeStamp == self.sizeStamp else {
                return .stale
            }
            return takeSizes(prepared, sized: sized)
        }
    }

    /// Enters another directory.
    internal func takeShow(_ prepared: Prepared, _ visit: PanelVisit) -> Outcome {
        adoptSort(prepared.sort)
        present(visit, lists: prepared.lists)
        prepared.forget()
        return .changed
    }

    /// Takes the list in another order; `table` holds the new place of every entry.
    internal func takeSort(_ prepared: Prepared, table: [UInt32]) -> Outcome {
        // Another order has been asked for since: this one is no longer wanted.
        if let requestedSort, requestedSort != prepared.sort {
            return .stale
        }
        let cursorPlace = cursorItem == nil ? nil : place(ofShown: cursor - offset)
        adoptSort(prepared.sort)
        replace(&prepared.lists, moves: .table(table), keepsTotals: true, isNewReading: false)
        if let cursorPlace, let index = shownIndex(ofPlace: Int(table[cursorPlace])) {
            cursor = index + offset
        }
        changed(.contents)
        return .changed
    }

    /// Takes an order the list is in already: only the name of the order changes.
    internal func takeSortName(_ prepared: Prepared) -> Outcome {
        if let requestedSort, requestedSort != prepared.sort {
            return .stale
        }
        adoptSort(prepared.sort)
        prepared.forget()
        stamp += 1
        changed(.contents)
        return .changed
    }

    /// Shows the list through another filter.
    internal func takeFilter(_ prepared: Prepared) -> Outcome {
        let cursorPlace = cursorItem == nil ? nil : place(ofShown: cursor - offset)
        filter = prepared.filter
        swap(&items, &prepared.lists.shown)
        shownPlaces = prepared.lists.places
        // What was shown before goes in the background; the list itself stays.
        Discard.later(&prepared.lists.shown)
        prepared.forget()
        // Sizes that were calculated while the filter was at work are in the list, not in
        // the copies the filter made.
        if shownPlaces != nil, let sized {
            for place in sized {
                let size = listedItems[place].computedSize
                if let shown = shownIndex(ofPlace: place), items[shown].computedSize != size {
                    items[shown].computedSize = size
                }
            }
        }
        // Items that are no longer shown lose their marks.
        if shownPlaces != nil, !marks.isEmpty { marks.formIntersection(shownBits()) }
        counted.setList(prepared.lists.tally)
        counted.selected = nil
        arrangementChanged(list: false, index: nil)
        cursor = cursorPlace.flatMap(shownIndex(ofPlace:)).map { $0 + offset } ?? min(cursor, max(rowCount - 1, 0))
        changed(.contents)
        return .changed
    }

    /// Takes a fresh reading of the directory the panel shows; without `moves` it holds the
    /// entries the panel has.
    internal func takeUpdate(_ prepared: Prepared, _ reading: Reading, moves: Moves?) -> Outcome {
        let focusName = reading.focus ?? cursorItem?.name
        let oldCursor = cursor
        let oldVolume = volume
        let oldState = ListState(isListed: isListed, isComplete: isComplete, isRefreshing: isRefreshing)
        adopt(reading.listing)
        if let moves {
            adoptSort(prepared.sort)
            replace(&prepared.lists, moves: moves, keepsTotals: false, isNewReading: true)
            isInArrivalOrder = sort.key == .unsorted
        } else {
            prepared.forget()
        }
        // A vanished cursor item leaves the cursor on the row that took its place (07 › State changes).
        // In a list that did not change, the item is where it was.
        cursor =
            focusName.flatMap { index(ofName: $0, near: oldCursor - offset) }.map { $0 + offset }
            ?? min(oldCursor, max(rowCount - 1, 0))
        // The flags count as well: whoever shows "refreshing" has to hear that it is over.
        let isDifferent =
            moves != nil || cursor != oldCursor || volume != oldVolume || !oldState.isListed
            || isComplete != oldState.isComplete || isRefreshing != oldState.isRefreshing
        guard isDifferent else {
            return .unchanged
        }
        changed(.contents)
        return .changed
    }

    /// Takes copies of the lists with calculated sizes written into them.
    internal func takeSizes(_ prepared: Prepared, sized: Bitset) -> Outcome {
        // No name was found: the lists stay.
        guard prepared.lists.listed.count == listedItems.count, !listedItems.isEmpty else {
            return .unchanged
        }
        // The same entries in the same places: the marks, the cursor, the index of names
        // and the versions stay as they are.
        swap(&listedItems, &prepared.lists.listed)
        swap(&items, &prepared.lists.shown)
        if lookups.index == nil { lookups.index = prepared.lists.index }
        self.sized = sized
        counted.setList(prepared.lists.tally)
        counted.selected = nil
        sizeStamp += 1
        changed(.selection)
        return .changed
    }
}
