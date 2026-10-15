/// What commands act on: the marked items, otherwise the item under the cursor.
extension PanelModel {
    /// The marks and what is shown, as they are now, in a value that can leave the main thread:
    /// taking it costs nothing (the lists are shared, the marks are a bit each), and everything it
    /// offers may be asked on any thread.
    ///
    /// For whoever needs the marked items of a long list (a drag, a command that starts a job)
    /// without holding up the main thread for making the list of them.
    public struct Operands: Sendable {
        /// What the panel shows (`PanelModel.items`).
        public let shownItems: [FileItem]
        /// The item under the cursor; nil on `[..]`.
        public let cursorItem: FileItem?
        /// How many items are marked.
        public let markedCount: Int
        /// `PanelModel.shownVersion` when the value was taken.
        public let shownVersion: Int
        /// Every entry of the list (`PanelModel.listedItems`).
        internal let listed: [FileItem]
        /// The marked places of `listed`.
        internal let marks: Bitset
        /// Which entries of `listed` are shown; nil when all are.
        internal let places: ShownPlaces?

        /// Whether the item at an index of `shownItems` is marked.
        public func isMarked(at index: Int) -> Bool {
            shownItems.indices.contains(index) && marks.contains(places.map { $0[index] } ?? index)
        }

        /// The marked items in the order of the list.
        public func markedItems() -> [FileItem] {
            marks.isEmpty ? [] : PanelModel.gathered(marks, of: listed, shown: shownItems)
        }

        /// The operand rule, as `PanelModel.operands()` has it: the marked items, otherwise
        /// the item under the cursor.
        public func items() -> [FileItem] {
            marks.isEmpty ? (cursorItem.map { [$0] } ?? []) : markedItems()
        }

        /// The indexes of the marked items in `shownItems`, rising.
        public func markedIndices() -> [Int] {
            var indices: [Int] = []
            indices.reserveCapacity(marks.count)
            guard let places else {
                return Array(marks)
            }
            // Both rise: one walk along the shown places.
            var next = 0
            for place in marks {
                while next < places.count, places[next] < place { next += 1 }
                if next < places.count, places[next] == place { indices.append(next) }
            }
            return indices
        }
    }

    /// Counts the changes of what is shown (`items`): of the list, of the filter and of the order.
    ///
    /// Indexes of `items` that were worked out in the background are good for as long as this
    /// number stays. (`listVersion` does not move with the filter.)
    public var shownVersion: Int { stamp }

    /// Whether there is anything to act on: marked items, or an item under the cursor.
    public var hasOperands: Bool { !marks.isEmpty || cursorItem != nil }

    /// Whether the operands include a file (something that is not a folder), found without
    /// making the list of them: it stops at the first one.
    ///
    /// The answer for the marks is kept until they change, so a toolbar or a menu may ask at
    /// every tick: a long selection of nothing but folders is walked once, not every time.
    public var hasOperandFile: Bool {
        if marks.isEmpty {
            return cursorItem.map { !$0.isDirectory } ?? false
        }
        switch markedFile {
        case .found:
            return true

        case .notFound:
            return false

        case .unknown:
            let found = marks.contains { !listedItems[$0].isDirectory }
            markedFile = found ? .found : .notFound
            return found
        }
    }

    /// The marked entries in the order of the list.
    ///
    /// For any thread.
    nonisolated internal static func gathered(_ marks: Bitset, of listed: [FileItem], shown: [FileItem]) -> [FileItem] {
        // Everything shown is marked: the list itself, not a copy of it.
        if marks.count == shown.count {
            return shown
        }
        guard marks.count > ListWork.pieceSize * 2 else {
            var operands: [FileItem] = []
            operands.reserveCapacity(marks.count)
            for place in marks { operands.append(listed[place]) }
            return operands
        }
        // A long selection is gathered on all cores.
        var places: [UInt32] = []
        places.reserveCapacity(marks.count)
        for place in marks { places.append(UInt32(place)) }
        return ListWork.picked(listed, at: places)
    }

    /// The operand rule: the selection in list order, otherwise the item under the cursor; nothing
    /// when the cursor is on `[..]`.
    ///
    /// Makes the list of the marked items (on all cores; nothing to make when everything shown is
    /// marked). **Not for the main thread on long lists** with many marks: `operandsSnapshot()` is
    /// taken here at no cost and makes the list on whatever thread asks it.
    public func operands() -> [FileItem] {
        guard !marks.isEmpty else {
            return cursorItem.map { [$0] } ?? []
        }
        return Self.gathered(marks, of: listedItems, shown: items)
    }

    /// The marks and what is shown, as they are now, for any thread (`Operands`).
    public func operandsSnapshot() -> Operands {
        Operands(
            shownItems: items,
            cursorItem: cursorItem,
            markedCount: marks.count,
            shownVersion: stamp,
            listed: listedItems,
            marks: marks,
            places: shownPlaces
        )
    }
}
