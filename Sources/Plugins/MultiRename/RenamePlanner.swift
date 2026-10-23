import AFMKernel
import Foundation

/// Works out what a set of renames collides with and in which order it can be carried out
/// (spec 09 › Name conflicts).
///
/// Pure: it sees locations only and never touches a file system.
///
/// Everywhere, `sources[i]` is where item i is, and `targets[i]` where it is to go: nil when
/// the item stays (no name, skipped), the source itself when the name does not change.
internal struct RenamePlanner {
    /// The longest a name can be, in UTF-8 bytes.
    internal static let longestName = 255

    /// Whether the file system takes `A.txt` and `a.txt` for the same name: in every folder,
    /// or only in the folders in `foldedFolders` (their `locationKey`s), as on a list whose
    /// items lie on several volumes.
    internal let foldsCase: Bool
    private let foldedFolders: Set<String>

    /// A planner for file systems that tell `A.txt` and `a.txt` apart.
    internal init() {
        self.init(foldsCase: false)
    }

    /// A planner for file systems that take `A.txt` and `a.txt` for the same name in every folder
    /// (`foldsCase`), or in none.
    internal init(foldsCase: Bool) {
        self.foldsCase = foldsCase
        foldedFolders = []
    }

    /// A planner for items on several volumes, of which the folders `foldedFolders` (their
    /// `locationKey`s) take `A.txt` and `a.txt` for the same name.
    internal init(foldedFolders: Set<String>) {
        foldsCase = false
        self.foldedFolders = foldedFolders
    }

    /// `report.txt` → `report (2).txt`; a folder keeps its dots.
    ///
    /// A name that the number would make too long for the file system is shortened at its base,
    /// between two characters.
    internal static func numbered(_ url: URL, _ number: Int, isFolder: Bool) -> URL {
        let name = url.lastPathComponent
        let (base, ext) = isFolder ? (name, "") : FileItem.split(name)
        let tail = " (\(number))" + (ext.isEmpty ? "" : "." + ext)
        var kept = base
        while kept.utf8.count + tail.utf8.count > longestName, !kept.isEmpty {
            kept.removeLast()
        }
        return url.deletingLastPathComponent().appending(name: kept + tail)
    }

    /// A location in the form in which the file system tells names apart.
    internal func key(_ url: URL) -> String {
        let plain = url.locationKey
        guard
            foldsCase || (!foldedFolders.isEmpty && foldedFolders.contains(url.deletingLastPathComponent().locationKey))
        else {
            return plain
        }
        return plain.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Whether the item changes place or name.
    ///
    /// Byte for byte: a name that differs only in how an accented letter is written (precomposed or
    /// not) is another name, though Swift calls the two equal.
    private func moves(_ source: URL, _ target: URL?) -> Bool {
        guard let target else {
            return false
        }
        return !target.locationKey.utf8.elementsEqual(source.locationKey.utf8)
    }

    /// The items whose new name collides: with each other, with an item that stays, or with a
    /// file outside the list. `existing` holds the keys of what is in the target folders now,
    /// the sources included.
    internal func conflicts(sources: [URL], targets: [URL?], existing: Set<String>) -> [Int: RenameStatus] {
        // The keys are most of the work; they are made on all cores.
        let finalKeys = Parallel.map(Array(sources.indices), serialBelow: 512) { key(targets[$0] ?? sources[$0]) }
        // The names that more than one item ends up with.
        var seen = Set<String>()
        var shared = Set<String>()
        for finalKey in finalKeys where !seen.insert(finalKey).inserted {
            shared.insert(finalKey)
        }
        let sourceKeys = Set(Parallel.map(sources, serialBelow: 512) { key($0) })
        var result: [Int: RenameStatus] = [:]
        for index in sources.indices where moves(sources[index], targets[index]) {
            let finalKey = finalKeys[index]
            if shared.contains(finalKey) {
                result[index] = .duplicate
            } else if existing.contains(finalKey), !sourceKeys.contains(finalKey) {
                result[index] = .exists
            }
        }
        return result
    }

    /// The targets with every collision renamed away to `name (2).ext`, `name (3).ext`, …
    /// Of several items that want the same free name, the first in the list gets it.
    internal func autoRenamed(sources: [URL], targets: [URL?], isFolder: [Bool], existing: Set<String>) -> [URL?] {
        var targets = targets
        let moving = sources.indices.compactMap { index in
            targets[index].flatMap { moves(sources[index], $0) ? (index: index, target: $0) : nil }
        }
        let movingSources = Set(moving.map { key(sources[$0.index]) })
        let wanted = Set(moving.map { key($0.target) })
        // Taken for good: what stays where it is, in the list or outside it.
        var claimed = existing.subtracting(movingSources)
        for index in sources.indices where !moves(sources[index], targets[index]) {
            claimed.insert(key(sources[index]))
        }
        // The next number to try for a name that many items want, so that the hundredth of
        // them does not count from 2 again.
        struct Wish: Hashable {
            var key: String
            var isFolder: Bool
        }
        var nextNumber: [Wish: Int] = [:]
        for (index, target) in moving {
            var chosen = target
            let targetKey = key(target)
            if claimed.contains(targetKey) {
                let wish = Wish(key: targetKey, isFolder: isFolder[index])
                var number = nextNumber[wish] ?? 2
                repeat {
                    chosen = Self.numbered(target, number, isFolder: isFolder[index])
                    number += 1
                } while claimed.contains(key(chosen)) || existing.contains(key(chosen)) || wanted.contains(key(chosen))
                nextNumber[wish] = number
            }
            claimed.insert(key(chosen))
            targets[index] = chosen
        }
        return targets
    }

    /// The targets with the items that collide, and those that this puts in the way of
    /// others in turn, left where they are ("Skip these files").
    ///
    /// An item that stays keeps its name, which another item may want: such an item is skipped as
    /// well, and so on along a chain. Works through a list of items to look at, once each.
    internal func skippingConflicts(sources: [URL], targets: [URL?], existing: Set<String>) -> [URL?] {
        var targets = targets
        var wanting: [String: [Int]] = [:]
        for (index, target) in zip(sources.indices, targets) {
            guard let target, moves(sources[index], target) else {
                continue
            }
            wanting[key(target), default: []].append(index)
        }
        // An item is taken out of the run when it is put on the list, so it is looked at once.
        var open = Array(conflicts(sources: sources, targets: targets, existing: existing).keys)
        for index in open {
            targets[index] = nil
        }
        while let index = open.popLast() {
            for other in wanting[key(sources[index])] ?? [] where targets[other] != nil {
                targets[other] = nil
                open.append(other)
            }
        }
        return targets
    }

    /// The items in list order, except that those which lie inside another folder of the list
    /// (and the folders that hold some) come first, the deepest first.
    private func insideOut(
        _ moving: [Int],
        sources: [URL],
        sourceKeys: [String],
        isFolder: [Bool],
        cancelled: () -> Bool
    ) -> [Int] {
        var folderKeys = Set<String>()
        var shallowest = Int.max
        for index in moving where isFolder.indices.contains(index) && isFolder[index] {
            folderKeys.insert(sourceKeys[index])
            shallowest = min(shallowest, sources[index].pathComponents.count)
        }
        guard !folderKeys.isEmpty else {
            return moving
        }
        var involved = Set<Int>()
        var holding = Set<String>()
        for (number, index) in moving.enumerated() {
            if number & 0xFFF == 0, cancelled() {
                return moving
            }
            var url = sources[index]
            // Up to the shallowest folder there is.
            while url.pathComponents.count > shallowest {
                url = url.deletingLastPathComponent()
                let ancestor = key(url)
                if folderKeys.contains(ancestor) {
                    involved.insert(index)
                    holding.insert(ancestor)
                }
            }
        }
        guard !involved.isEmpty else {
            return moving
        }
        for index in moving where holding.contains(sourceKeys[index]) {
            involved.insert(index)
        }
        let depth = { (index: Int) in involved.contains(index) ? sources[index].pathComponents.count : -1 }
        // Stable: the items of equal depth stay in list order.
        return moving.enumerated()
            .sorted { first, second in
                let (firstDepth, secondDepth) = (depth(first.element), depth(second.element))
                return firstDepth != secondDepth ? firstDepth > secondDepth : first.offset < second.offset
            }
            .map(\.element)
    }

    /// The renames in an order that works: list order, except that an item whose new name
    /// is still held by another item of the list waits for that one.
    ///
    /// A ring of such items (`1.txt` ↔ `2.txt`) is opened by moving one of them to a temporary name
    /// first. `temporaryName` gives that name for an item; it must be free in the item's folder.
    ///
    /// With `isFolder` (one flag per item; empty when it is not known), a folder and what lies in it
    /// that are renamed in one run are done inside out, deepest first: the items inside a folder are
    /// still where the list says they are when it is their turn, which they would not be once the
    /// folder has a new name. Without `temporaryName` the temporary names are `.afm-rename-…-N.tmp`.
    ///
    /// `cancelled` is looked at every few thousand items; a cancelled plan is cut short and must
    /// not be carried out. The keys of all items, which are most of the work, are made on all cores.
    internal func steps(
        sources: [URL],
        targets: [URL?],
        isFolder: [Bool],
        temporaryName: ((Int) -> String)?,
        cancelled: () -> Bool
    ) -> [RenameStep] {
        let token = UUID().uuidString.prefix(8)
        let nameFor = temporaryName ?? { ".afm-rename-\(token)-\($0).tmp" }
        var moving = sources.indices.filter { moves(sources[$0], targets[$0]) }
        guard !moving.isEmpty, !cancelled() else {
            return []
        }
        let sourceKeys = Parallel.map(sources, serialBelow: 512) { key($0) }
        let targetKeys: [String?] = Parallel.map(Array(targets), serialBelow: 512) { $0.map(key) }
        if !isFolder.isEmpty, moving.count > 1 {
            moving = insideOut(
                moving,
                sources: sources,
                sourceKeys: sourceKeys,
                isFolder: isFolder,
                cancelled: cancelled
            )
        }
        var order = RenameStepOrder(
            sources: sources,
            // Where each item goes; only those that move are looked at.
            destinations: sources.indices.map { targets[$0] ?? sources[$0] },
            sourceKeys: sourceKeys,
            targetKeys: targetKeys,
            temporaryName: nameFor
        )
        return order.steps(for: moving, cancelled: cancelled)
    }
}
