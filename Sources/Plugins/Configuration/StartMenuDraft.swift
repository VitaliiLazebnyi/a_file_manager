/// The Start menu while it is being edited (spec 14 › The Change start menu dialog).
///
/// Each entry carries its shortcut as text; the keys themselves live in the key bindings.
internal struct StartMenuDraft: Equatable {
    /// An entry of the menu with its shortcut.
    internal struct Row: Equatable {
        /// The entry as it will be stored.
        internal var entry: StartMenuEntry
        /// The shortcut as the user wrote it; empty for none.
        internal var shortcut = ""
    }

    /// The entries in menu order.
    internal var rows: [Row] = []

    /// Inserts `row` directly after `index` (at the end without one) and returns where it went.
    @discardableResult
    internal mutating func insert(_ row: Row, after index: Int?) -> Int {
        let position = index.map { min($0 + 1, rows.count) } ?? rows.count
        rows.insert(row, at: max(0, position))
        return position
    }

    /// Moves the row at `index` up (-1) or down (+1); returns where it is afterwards.
    @discardableResult
    internal mutating func move(_ index: Int, by offset: Int) -> Int {
        let target = index + offset
        guard rows.indices.contains(index), rows.indices.contains(target) else {
            return index
        }
        rows.swapAt(index, target)
        return target
    }
}
