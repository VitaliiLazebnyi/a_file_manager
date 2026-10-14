/// Marking items.
extension PanelModel {
    /// The number of marked items, one for every marked entry, also where two names read the same.
    public var selectionCount: Int { marks.count }
    /// Whether anything is marked.
    ///
    /// Costs nothing.
    public var hasSelection: Bool { !marks.isEmpty }

    /// Marks the item of a row, or takes its mark away.
    public func toggleSelection(row: Int) {
        let index = row - offset
        guard items.indices.contains(index) else {
            return
        }
        let place = place(ofShown: index)
        let isSelected = !marks.remove(place)
        if isSelected { marks.insert(place) }
        count(items[index], selected: isSelected)
        changed(.selection)
    }

    /// Marks or unmarks the items of a range of rows; `[..]` and rows outside the list are
    /// left out.
    public func setSelected(_ selected: Bool, rows: ClosedRange<Int>) {
        // Rows outside the list are not walked: a range may be far longer than the list.
        let first = max(rows.lowerBound, offset) - offset
        let last = min(rows.upperBound, items.count - 1 + offset) - offset
        if first <= last {
            for index in first...last { mark(index, selected) }
        }
        changed(.selection)
    }

    /// Marks or unmarks the shown items with these names, and announces it once.
    ///
    /// A name stands for the items written exactly like it (in a list gathered from several folders
    /// that can be more than one), else for the item that reads the same, as `row(ofName:)` finds
    /// it. Every name is looked up (the first calls on a long list make an index of all its names):
    /// **not for the main thread with many names or on long lists**; the calls that take rows or
    /// indexes look nothing up.
    public func setSelected(_ selected: Bool, names: some Sequence<String>) {
        for name in names {
            // Only what is shown can be marked.
            for place in shownPlaces(named: name) where selected ? marks.insert(place) : marks.remove(place) {
                count(listedItems[place], selected: selected)
            }
        }
        changed(.selection)
    }

    /// Makes the shown items with these names the whole selection, and announces it once.
    ///
    /// Looks every name up, like `setSelected(_:names:)`: **not for the main thread with many names
    /// or on long lists**.
    public func setSelection(names: some Sequence<String>) {
        var bits = Bitset(size: listedItems.count)
        for name in names {
            for place in shownPlaces(named: name) { bits.insert(place) }
        }
        setMarks(bits)
    }

    /// Marks every shown item.
    ///
    /// However long the list, this takes no time worth the name: the marks are one bit per entry,
    /// and the figures of the status line are those of the list.
    public func selectAll() {
        _ = totals
        let all = counted.list.map { list in
            Totals(selected: Counts(bytes: list.totalBytes, files: list.totalFiles, folders: list.totalFolders))
        }
        setMarks(shownBits(), totals: counted.listIsPlain ? all : nil)
    }

    /// Takes every mark away.
    public func clearSelection() {
        setMarks(Bitset(size: listedItems.count), totals: Totals())
    }

    /// Marks what is not marked and unmarks what is.
    public func invertSelection() {
        // The figures of the rest are those of the list less those of the marked.
        let (list, selected) = (totals, counted.selected)
        var rest: Totals?
        if counted.listIsPlain, let selected {
            let counts = Counts(
                bytes: list.totalBytes - selected.selectedBytes,
                files: list.totalFiles - selected.selectedFiles,
                folders: list.totalFolders - selected.selectedFolders
            )
            rest = Totals(selected: counts)
        }
        var bits = shownBits()
        bits.subtract(marks)
        setMarks(bits, totals: rest)
    }

    /// Select group / Unselect group with a file mask.
    ///
    /// One pass over the list on all cores (about 15 ms for a million names), on the calling
    /// thread, like `select(where:)`.
    public func select(mask: String, select: Bool = true) {
        let fileMask = FileMask(mask)
        self.select(where: { fileMask.matches($0.name) }, select: select)
    }

    /// Marks (or unmarks) the shown items `matches` holds for, and announces it once.
    ///
    /// A long list is looked through on all cores: `matches` is then called from several threads at
    /// once and must be a function of the item alone. With a test that costs more than a look at
    /// the name this is **not for the main thread on long lists**: `rows(of:where:)` does it in the
    /// background.
    @preconcurrency
    public func select(where matches: @Sendable (FileItem) -> Bool, select: Bool = true) {
        let found = ListWork.matching(listedItems, among: shownPlaces == nil ? nil : shownBits(), where: matches)
        var bits = marks
        if select { bits.formUnion(found) } else { bits.subtract(found) }
        setMarks(bits)
    }

    /// Takes the marks off the items with these names.
    ///
    /// A name written like a marked item means that item; one written differently means the marked
    /// item that reads the same. Looks every name up: **not for the main thread with many names**;
    /// a caller that knows the rows uses `setSelection(_:_:)` with `.remove`, or
    /// `setSelected(false, indices:shownVersion:)`.
    public func deselect(_ names: some Sequence<String>) {
        var left = marks
        for name in names where !left.isEmpty {
            // The other writing is looked for only when no item is written like the name.
            for place in shownPlaces(named: name) { left.remove(place) }
        }
        setMarks(left)
    }

    /// Marks or unmarks the items at these indexes of `items`, with no name looked up, and
    /// announces it once.
    ///
    /// Does nothing and returns false when what is shown has changed since `shownVersion` was
    /// `version`.
    @discardableResult
    public func setSelected(_ selected: Bool, indices: some Sequence<Int>, shownVersion version: Int) -> Bool {
        guard version == stamp else {
            return false
        }
        for index in indices where items.indices.contains(index) { mark(index, selected) }
        changed(.selection)
        return true
    }

    /// Makes the items at these indexes of `items` the whole selection.
    ///
    /// Does nothing and returns false when what is shown has changed since `shownVersion` was
    /// `version`.
    @discardableResult
    public func setSelection(indices: some Sequence<Int>, shownVersion version: Int) -> Bool {
        guard version == stamp else {
            return false
        }
        var bits = Bitset(size: listedItems.count)
        for index in indices where items.indices.contains(index) { bits.insert(place(ofShown: index)) }
        setMarks(bits)
        return true
    }

    /// Marks or unmarks the item at an index of `items`, keeping the totals in step.
    internal func mark(_ index: Int, _ selected: Bool) {
        let place = place(ofShown: index)
        if selected ? marks.insert(place) : marks.remove(place) { count(items[index], selected: selected) }
    }

    /// Keeps the selected half of the totals in step with one item's mark.
    internal func count(_ item: FileItem, selected: Bool) {
        guard var totals = counted.selected else {
            return
        }
        if item.isFolder {
            totals.selectedFolders += selected ? 1 : -1
        } else {
            totals.selectedFiles += selected ? 1 : -1
        }
        let size = item.isFolder ? (item.computedSize ?? 0) : item.size
        // A size below zero makes the sum depend on its order: counted afresh.
        counted.selected = size < 0 ? nil : totals.adding(bytes: selected ? size : -size, selected: true)
    }

    /// Makes `bits` the marks and announces it; `totals` is the selected half of the totals,
    /// when the caller knows it.
    internal func setMarks(_ bits: Bitset, totals: Totals?) {
        marks = bits
        counted.selected = totals
        changed(.selection)
    }

    /// Makes `bits` the marks and announces it; the totals are counted when asked for.
    internal func setMarks(_ bits: Bitset) {
        setMarks(bits, totals: nil)
    }
}
