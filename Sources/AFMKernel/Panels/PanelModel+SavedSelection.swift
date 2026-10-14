/// Save Selection and Restore Selection.
extension PanelModel {
    /// Keeps the marks for Restore Selection (spec 03 › Selection).
    public func saveSelection() {
        saved = marks.isEmpty ? .nothing : .places(marks)
    }

    /// Marks what Save Selection kept: the same entries of the same list, or, in another
    /// folder, the shown entries of the same names.
    public func restoreSelection() {
        var bits: Bitset
        switch saved {
        case .nothing:
            bits = Bitset(size: listedItems.count)

        case .places(let places):
            bits = places
            if shownPlaces != nil { bits.formIntersection(shownBits()) }

        case .names(let names):
            bits = shownMarks(named: names)

        case .remains(let remains, let places):
            bits = shownMarks(at: places, of: remains.lists[0])
        }
        setMarks(bits)
    }

    /// The shown entries with these names.
    internal func shownMarks(named names: Set<ExactName>) -> Bitset {
        var bits = Bitset(size: listedItems.count)
        guard names.count < items.count / 4 else {
            // Many names: one pass over what is shown.
            for index in items.indices where names.contains(ExactName(items[index].name)) {
                bits.insert(place(ofShown: index))
            }
            return bits
        }
        for name in names {
            for place in places(ofExactly: name.name) where shownIndex(ofPlace: place) != nil {
                bits.insert(place)
            }
        }
        return bits
    }

    /// The shown entries named like the entries at `places` of the list `old`.
    internal func shownMarks(at places: Bitset, of old: [FileItem]) -> Bitset {
        var bits = Bitset(size: listedItems.count)
        guard places.count > Self.indexedAbove else {
            for place in places {
                for found in self.places(ofExactly: old[place].name) where shownIndex(ofPlace: found) != nil {
                    bits.insert(found)
                }
            }
            return bits
        }
        // Very many names to find: all of them at once, on all cores.
        let finder = NameFinder(listedItems, index: lookups.index)
        let table = ListWork.moves(from: old, to: finder)
        lookups.index = finder.index
        for place in places {
            let found = table[place]
            if found != .max { bits.insert(Int(found)) }
        }
        if shownPlaces != nil { bits.formIntersection(shownBits()) }
        return bits
    }
}
