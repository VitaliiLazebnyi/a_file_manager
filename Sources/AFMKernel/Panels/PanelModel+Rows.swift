import Foundation

/// Rows, the cursor, and finding entries by name.
extension PanelModel {
    /// Whether the first row is `[..]`.
    public var hasParentRow: Bool { parent != nil }
    /// The rows, `[..]` included.
    public var rowCount: Int { items.count + offset }
    /// The item under the cursor; nil on `[..]`.
    public var cursorItem: FileItem? { item(atRow: cursor) }
    /// The file under the cursor; nil on a folder and on `[..]`.
    public var cursorFile: FileItem? { cursorItem.flatMap { $0.isFolder ? nil : $0 } }
    /// True while the cursor is on the `[..]` row.
    public var cursorIsOnParentRow: Bool { hasParentRow && cursor == 0 }

    /// How many rows come before the first item: one for `[..]`.
    internal var offset: Int { hasParentRow ? 1 : 0 }

    /// The item of a row; `nil` for `[..]` and for rows outside the list.
    public func item(atRow row: Int) -> FileItem? {
        let index = row - offset
        return items.indices.contains(index) ? items[index] : nil
    }

    /// The row of the item with this name.
    ///
    /// Of several items whose names read the same, the one written exactly like `name`; a name
    /// written differently from every item finds one that reads the same.
    public func row(ofName name: String) -> Int? {
        index(ofName: name).map { $0 + offset }
    }

    /// Whether the item of a row is marked.
    public func isSelected(row: Int) -> Bool {
        let index = row - offset
        return !marks.isEmpty && items.indices.contains(index) && marks.contains(place(ofShown: index))
    }

    /// Whether this entry of the list is marked: the entry itself, not another whose name merely
    /// reads the same.
    ///
    /// Of several entries with the very same name, the one at the item's location.
    public func isSelected(_ item: FileItem) -> Bool {
        guard !marks.isEmpty else {
            return false
        }
        let found = places(ofExactly: item.name)
        guard found.count > 1 else {
            return found.first.map(marks.contains) ?? false
        }
        // Several entries of this very name: the one that is this item; if none is quite
        // (the item is an older reading), the likeliest of those that are shown.
        if let own = found.first(where: { listedItems[$0] == item }) {
            return marks.contains(own)
        }
        let shown = found.filter { shownIndex(ofPlace: $0) != nil }
        return ListWork.twin(of: item, among: shown.isEmpty ? found : shown, in: listedItems).map(marks.contains)
            ?? false
    }

    /// Moves the cursor from a command; the row is kept inside the list.
    public func moveCursor(to row: Int) {
        cursor = max(0, min(row, max(rowCount - 1, 0)))
        changed(.cursor)
    }

    /// The place in `listedItems` of the entry shown at an index of `items`.
    internal func place(ofShown index: Int) -> Int {
        shownPlaces.map { $0[index] } ?? index
    }

    /// Where in `items` the entry at a place of `listedItems` is shown; nil when it is not.
    internal func shownIndex(ofPlace place: Int) -> Int? {
        guard let shownPlaces else {
            return place < listedItems.count ? place : nil
        }
        return shownPlaces.row(ofPlace: place)
    }

    /// The shown entries as a set of places.
    internal func shownBits() -> Bitset {
        shownPlaces?.bits(size: listedItems.count) ?? Bitset.full(listedItems.count)
    }

    /// Every place of `listedItems` whose entry is written exactly like `name`, rising.
    internal func places(ofExactly name: String) -> [Int] {
        lookups.places(ofExactly: name, in: listedItems)
    }

    /// The place of an entry that was at `hint`, or near it, in an earlier list.
    internal func place(of item: FileItem, near hint: Int) -> Int? {
        ListWork.place(of: item, near: hint, in: listedItems) { places(ofExactly: $0) }
    }

    /// The place of a name in `items`: the entry written exactly like it, else one that reads
    /// the same.
    internal func index(ofName name: String, near hint: Int?) -> Int? {
        if let hint, items.indices.contains(hint), ExactName.areSame(items[hint].name, name) {
            return hint
        }
        return index(ofName: name)
    }

    /// The place of a name in `items`, with no hint where it may be.
    internal func index(ofName name: String) -> Int? {
        firstShown(ofExactly: name) ?? alike(name)
    }

    /// The first shown entry written exactly like `name`.
    internal func firstShown(ofExactly name: String) -> Int? {
        for place in places(ofExactly: name) {
            if let shown = shownIndex(ofPlace: place) {
                return shown
            }
        }
        return nil
    }

    /// A shown entry whose name reads like `name` and is written differently.
    internal func alike(_ name: String) -> Int? {
        // A name of plain ASCII reads like no other writing than its own composed form, and
        // that is looked up as it is written.
        let composed = name.precomposedStringWithCanonicalMapping
        if !ExactName.areSame(composed, name), let shown = firstShown(ofExactly: composed) {
            return shown
        }
        return lookups.row(alike: name, in: items)
    }

    /// The shown entries a name stands for: all that are written exactly like it (a list
    /// gathered from several folders can hold a name more than once), else the one that reads
    /// the same.
    internal func shownPlaces(named name: String) -> [Int] {
        let exact = places(ofExactly: name).filter { shownIndex(ofPlace: $0) != nil }
        if !exact.isEmpty {
            return exact
        }
        return alike(name).map { [place(ofShown: $0)] } ?? []
    }
}
