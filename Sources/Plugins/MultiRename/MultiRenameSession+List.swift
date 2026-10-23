import AFMKernel
import Foundation

/// The list: sorting, moving and taking out rows, and "next step".
extension MultiRenameSession {
    /// Sorts by a column; the order drives the counter `[C]`.
    ///
    /// The keys are worked out once per row, and a long list is sorted in the background (the list
    /// shows the new order when it is ready; a change of the list in the meantime drops the result,
    /// and of two sorts asked for in a row, the second wins).
    internal func sort(by key: SortKey, ascending: Bool) {
        guard !isBusy else {
            return
        }
        let rows = entries
        // Weak: done in the background, the order may come when the session has gone.
        let apply: @MainActor @Sendable ([Int]) -> Void = { [weak self] order in
            self?.reorder(order)
            self?.dropGivenNames()
            self?.listChanged(keepingFolders: true)
        }
        sortRequest += 1
        guard previewsInBackground, entries.count >= Self.backgroundSortThreshold else {
            apply(RenameSortOrder.permutation(of: rows, by: key, ascending: ascending))
            return
        }
        let (generation, request) = (listGeneration, sortRequest)
        isComputing = true
        sortQueue.async { [weak self] in
            let order = RenameSortOrder.permutation(of: rows, by: key, ascending: ascending)
            DispatchQueue.main.async { [weak self] in
                guard let self, listGeneration == generation, sortRequest == request else {
                    return
                }
                apply(order)
            }
        }
    }

    /// Puts the rows in the order given by `order` (the old indexes, new row first).
    internal func reorder(_ order: [Int]) {
        let (oldEntries, oldNames, oldStatuses) = (entries, newNames, statuses)
        entries = order.map { oldEntries[$0] }
        newNames = order.map { oldNames[$0] }
        statuses = order.map { oldStatuses[$0] }
    }

    /// Moves the rows one place up (-1) or down (+1) and returns where they are now.
    @discardableResult
    internal func move(_ indexes: IndexSet, by offset: Int) -> IndexSet {
        guard !isBusy, offset == 1 || offset == -1, let first = indexes.first, let last = indexes.last,
            offset < 0 ? first > 0 : last < entries.count - 1
        else {
            return indexes
        }
        for index in offset < 0 ? Array(indexes) : indexes.reversed() {
            entries.swapAt(index, index + offset)
            newNames.swapAt(index, index + offset)
            statuses.swapAt(index, index + offset)
        }
        listChanged(keepingFolders: true)
        return IndexSet(indexes.map { $0 + offset })
    }

    /// Moves rows in front of the row that is at `destination` now (drag and drop).
    @discardableResult
    internal func move(_ indexes: IndexSet, to destination: Int) -> IndexSet {
        guard !isBusy else {
            return indexes
        }
        let moved = indexes.filter(entries.indices.contains)
        guard !moved.isEmpty else {
            return []
        }
        let insertion = destination - indexes.filter { $0 < destination }.count
        var order = entries.indices.filter { !indexes.contains($0) }
        order.insert(contentsOf: moved, at: min(max(insertion, 0), order.count))
        reorder(order)
        listChanged(keepingFolders: true)
        return IndexSet(integersIn: insertion..<(insertion + moved.count))
    }

    /// Takes rows out of the rename set.
    internal func remove(_ indexes: IndexSet) {
        guard !isBusy else {
            return
        }
        reorder(entries.indices.filter { !indexes.contains($0) })
        dropGivenNames()
        listChanged(keepingFolders: true)
    }

    /// "Next step" (F5): the computed names become the old names, so that another set of
    /// rules can be applied on top; the fields go back to "no change".
    ///
    /// Nothing is renamed yet.
    internal func nextStep() {
        guard !isBusy else {
            return
        }
        let (oldEntries, names) = (entries, newNames)
        @Sendable
        func renamed() -> [RenameEntry] {
            var updated = oldEntries
            for index in updated.indices {
                if let name = names[index], RenameEngine.invalidity(of: name) == nil {
                    updated[index].name = name
                }
            }
            return updated
        }
        // Weak: done in the background, the rows may come when the session has gone.
        let finish: @MainActor @Sendable ([RenameEntry]) -> Void = { [weak self] in self?.reordered($0) }
        guard previewsInBackground, oldEntries.count >= Self.backgroundSortThreshold else {
            finish(renamed())
            return
        }
        let generation = listGeneration
        isComputing = true
        sortQueue.async { [weak self] in
            let updated = renamed()
            DispatchQueue.main.async { [weak self] in
                guard let self, listGeneration == generation else {
                    return
                }
                finish(updated)
            }
        }
    }

    /// A given name belongs to a place in the list; a list in another order has none.
    internal func dropGivenNames() {
        givenNames = []
    }

    /// Takes the rows in their new order.
    private func reordered(_ updated: [RenameEntry]) {
        entries = updated
        givenNames = []
        // The subjects carry the old names.
        listGeneration += 1
        cache = cache.forChangedOrder()
        if settings == .unchanged {
            listChanged(keepingFolders: true)
        } else {
            settings = .unchanged
        }
        onChange?()
    }
}
