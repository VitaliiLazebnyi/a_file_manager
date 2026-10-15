/// Sets of rows found in the background.
extension PanelModel {
    /// A set of shown rows of one model, as the list, the filter and the order were when its
    /// basis was taken (`rows(of:where:)`, `setSelection(_:_:)`).
    public struct RowSet: Sendable {
        /// The basis's `stamp`: the set fits the model only while the model's is the same.
        internal let stamp: Int
        /// The places of the rows' entries.
        internal let bits: Bitset
    }

    /// The shown rows `matches` holds for.
    ///
    /// **For any thread**; a long list is looked through on all cores, so `matches` must be a
    /// function of the item alone.
    @preconcurrency
    nonisolated public static func rows(of basis: Basis, where matches: @Sendable (FileItem) -> Bool) -> RowSet {
        let shown = basis.places.map { $0.bits(size: basis.listedItems.count) }
        return RowSet(stamp: basis.stamp, bits: ListWork.matching(basis.listedItems, among: shown, where: matches))
    }

    /// Changes the selection by a set of rows that was worked out in the background.
    ///
    /// Returns false, and does nothing, when the list, the filter or the order have changed since
    /// the set's basis was taken: the caller works the set out again.
    @discardableResult
    public func setSelection(_ rows: RowSet, _ change: SelectionChange = .replace) -> Bool {
        guard rows.stamp == stamp, rows.bits.size == listedItems.count else {
            return false
        }
        var bits = rows.bits
        switch change {
        case .replace:
            break

        case .add:
            bits.formUnion(marks)

        case .remove:
            bits = marks
            bits.subtract(rows.bits)
        }
        setMarks(bits)
        return true
    }
}
