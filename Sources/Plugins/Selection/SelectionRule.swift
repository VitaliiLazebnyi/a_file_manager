import AFMKernel
import Foundation

/// A mask or a selection type, ready to be asked which entries of a list it selects.
///
/// A value without shared state; `names` may run on any thread.
internal struct SelectionRule {
    /// The mask the names are matched against (for a type, its mask).
    internal let mask: SelectionMask
    /// The selection type whose further conditions apply, or nil for a plain mask.
    internal let type: SelectionType?

    /// Whether the rule looks at other entries than the one it judges (`A>B` takes the files
    /// that belong to the matching ones): such a rule has to be run over the whole list.
    internal var isPairwise: Bool { mask.pairsRelatedFiles }

    /// A rule of a mask typed into Select group.
    internal init(mask text: String) {
        mask = SelectionMask(text)
        type = nil
    }

    /// A rule of a saved selection type: its mask and its further conditions.
    internal init(_ type: SelectionType) {
        mask = SelectionMask(type.mask)
        self.type = type
    }

    /// The names of the entries the rule selects, as a set (two names that read the same are
    /// one member; use `matching` where each entry counts).
    internal func names(among items: [FileItem], base: URL, now: Date) -> Set<String> {
        Set(matching(among: items, base: base, now: now))
    }

    /// The names of the entries the rule selects, one per entry in list order, written as the
    /// entries have them. `base` is the directory the list belongs to; path-limited masks are
    /// read relative to it; `now` is the moment a type's age in days is counted back from.
    internal func matching(among items: [FileItem], base: URL, now: Date) -> [String] {
        matchingIndices(among: items, base: base, now: now, scope: .both) { false }.map { items[$0].name }
    }

    /// The same as places in `items`, of the entries `scope` lets through, ending early once
    /// `cancelled` says so (the places found so far are then of no use).
    ///
    /// Whether a regular expression of the mask ran out of time is told by `mask.timedOut`.
    internal func matchingIndices(
        among items: [FileItem],
        base: URL,
        now: Date,
        scope: SelectionScope,
        cancelled: () -> Bool
    ) -> [Int] {
        let entry = entryMaker(base: base)
        let entries = items.map(entry)
        var found: [Int] = []
        for (index, isSelected) in mask.selected(entries, cancelled: cancelled).enumerated()
        where isSelected && scope.contains(items[index]) && (type?.accepts(items[index], now: now) ?? true) {
            found.append(index)
        }
        return found
    }

    /// Whether the rule selects one entry on its own, for a rule that is not `isPairwise`.
    ///
    /// A function of the entry alone, so it may be asked from several threads at once.
    internal func probe(base: URL, now: Date) -> @Sendable (FileItem) -> Bool {
        let (ruleMask, ruleType, entry) = (mask, type, entryMaker(base: base))
        return { item in ruleMask.matches(entry(item)) { false } && (ruleType?.accepts(item, now: now) ?? true) }
    }

    /// What a mask is asked about an entry: `base` is the directory the list belongs to.
    private func entryMaker(base: URL) -> @Sendable (FileItem) -> MaskEntry {
        let needsDirectories = mask.needsDirectories
        let baseParts = needsDirectories ? base.pathComponents.filter { $0 != "/" } : []
        return { item in
            // A list gathered from elsewhere (a branch view, a search result) names its entries
            // by path; the mask is tried against the file's own name, and the selection is
            // still keyed by the entry's name, which is unique in such a list.
            let name = item.name.utf8.contains(UInt8(ascii: "/")) ? item.url.lastPathComponent : item.name
            guard needsDirectories else {
                return MaskEntry(name: name, isFolder: item.isFolder)
            }
            let parts = item.url.deletingLastPathComponent().pathComponents.filter { $0 != "/" }
            // Entries of a list gathered from elsewhere (a search result) keep their whole path.
            let directory = parts.starts(with: baseParts) ? Array(parts.dropFirst(baseParts.count)) : parts
            return MaskEntry(name: name, isFolder: item.isFolder, directory: directory)
        }
    }
}
