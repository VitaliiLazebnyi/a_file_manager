public import AFMKernel
import Foundation

/// Pairing and classification: which entries of two folders face each other, and what they are to each other.
extension SyncComparison {
    /// Whether the dates of these two places may be rounded or shifted by their file systems:
    /// anything but APFS and HFS+ on this Mac (FAT and exFAT keep two-second dates, shares and
    /// servers whatever theirs do, archives two seconds).
    internal static func needsTolerance(_ first: URL, _ second: URL, fileSystems _: FileSystemRegistry) -> Bool {
        func exact(_ url: URL) -> Bool {
            guard url.isFileURL else {
                return false
            }
            var info = statfs()
            guard statfs(url.path, &info) == 0 else {
                return false
            }
            let type = withUnsafeBytes(of: info.f_fstypename) { bytes in
                String(bytes: bytes.prefix { byte in byte != 0 }, encoding: .utf8)
            }
            return type == "apfs" || type == "hfs"
        }
        return !(exact(first) && exact(second))
    }

    // MARK: Classification

    /// What two files of the same name are to each other, by size and date alone.
    ///
    /// The second value says that only reading them can tell (spec 09 › Comparison algorithm).
    public static func classify(left: FileItem, right: FileItem, options: SyncOptions) -> (
        state: SyncState, needsContent: Bool
    ) {
        if !options.ignoreDate {
            let difference = left.modified.timeIntervalSince(
                right.modified.addingTimeInterval(Double(options.timeOffsetHours) * 3_600)
            )
            let tolerance = Double(max(0, options.toleranceSeconds))
            // Whole seconds are compared: a file system that keeps less than a nanosecond or
            // millisecond (exFAT, HFS+, SMB) would otherwise show every copy from APFS as older.
            func within(_ seconds: Double) -> Bool { seconds < 1 || seconds <= tolerance }
            let sameTime =
                within(abs(difference)) || (options.ignoreOneHourDifference && within(abs(abs(difference) - 3_600)))
            if !sameTime {
                return (difference > 0 ? .leftNewer : .rightNewer, false)
            }
        }
        guard left.size == right.size else {
            return (.different, false)
        }
        return options.byContent ? (.pending, true) : (.equal, false)
    }

    /// The pairs in the order of their names, digits by their value (`file2` before `file10`),
    /// as Finder shows names.
    ///
    /// The order is the kernel's (`Sorter`), which is an order for any names: Foundation's
    /// localized comparison is none, and it ends the program for certain names (K001), which a
    /// folder on a server or in an archive may well hold. Each name's key is made once; the pairs
    /// themselves (large values) are moved once.
    internal static func sorted(_ pairs: [Pair]) -> [Pair] {
        Sorter.sorted(pairs, numeric: true, byName: \.name)
    }

    /// Puts the entries of two folders side by side: by exact name (the same bytes) first, then
    /// what is left over by name without regard to case or Unicode form.
    ///
    /// Two names that differ only in form (NFC and NFD) are two files and keep their own rows.
    internal static func pair(_ leftItems: [FileItem], _ rightItems: [FileItem]) -> [Pair] {
        var rightByName: [[UInt8]: Int] = [:]
        for (index, item) in rightItems.enumerated() where rightByName[Array(item.name.utf8)] == nil {
            rightByName[Array(item.name.utf8)] = index
        }
        var matched = [Bool](repeating: false, count: rightItems.count)
        var pairs: [Pair] = []
        var unmatched: [FileItem] = []
        for item in leftItems {
            if let index = rightByName[Array(item.name.utf8)], !matched[index] {
                matched[index] = true
                pairs.append(Pair(name: item.name, left: item, right: rightItems[index]))
            } else {
                unmatched.append(item)
            }
        }
        // What is left of the right side, in order, found by the name without its case.
        let leftovers = rightItems.indices.filter { index in !matched[index] }.map { index in rightItems[index] }
        return pairs + pairUnmatched(unmatched, with: leftovers, leftItems: leftItems, rightItems: rightItems)
    }

    /// The pairs of what exact names did not pair: by the name without its case, else alone, marked where its
    /// name collides with one paired on the other side.
    private static func pairUnmatched(
        _ unmatched: [FileItem],
        with leftovers: [FileItem],
        leftItems: [FileItem],
        rightItems: [FileItem]
    ) -> [Pair] {
        var byFoldedName: [String: [Int]] = [:]
        for (index, item) in leftovers.enumerated() {
            byFoldedName[folded(item.name), default: []].append(index)
        }
        var next: [String: Int] = [:]
        var taken = [Bool](repeating: false, count: leftovers.count)
        // The names of both folders by their folded form: a name left over whose form is in use on the
        // other side collides with the name that is paired there.
        let foldedRight = Set(rightItems.map { item in folded(item.name) })
        let foldedLeft = Set(leftItems.map { item in folded(item.name) })
        var pairs: [Pair] = []
        for item in unmatched {
            let key = folded(item.name)
            if let indices = byFoldedName[key], case let position = next[key, default: 0], position < indices.count {
                next[key] = position + 1
                taken[indices[position]] = true
                let other = leftovers[indices[position]]
                // Names that differ only in form are the same name to this file system.
                pairs.append(Pair(name: item.name, left: item, right: other, isExactMatch: item.name == other.name))
            } else {
                pairs.append(Pair(name: item.name, left: item, right: nil, collides: foldedRight.contains(key)))
            }
        }
        for (index, item) in leftovers.enumerated() where !taken[index] {
            pairs.append(
                Pair(name: item.name, left: nil, right: item, collides: foldedLeft.contains(folded(item.name)))
            )
        }
        return pairs
    }

    /// A name without its case, as a file system that ignores case sees it.
    private static func folded(_ name: String) -> String { name.folding(options: .caseInsensitive, locale: nil) }
}
