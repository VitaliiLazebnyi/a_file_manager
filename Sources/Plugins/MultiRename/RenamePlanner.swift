import AFMKernel
import Foundation

/// How an item of the rename list stands (spec 09 › Start!, collisions, Undo, Result list).
enum RenameStatus: Equatable {
    /// The new name is the old one.
    case unchanged
    case ready
    /// The masks give no name: `<Error!>`.
    case error
    /// The name cannot be given to a file; the text says why.
    case invalid(String)
    /// Another item of the list ends up with the same name.
    case duplicate
    /// A file that is not being renamed away already has the name.
    case exists

    var isConflict: Bool { self == .duplicate || self == .exists }
}

/// One rename the file system is asked for.
struct RenameStep: Equatable {
    enum Kind: Equatable {
        case direct
        /// Out of the way, to a temporary name, because the item's own new name is still taken
        /// by another item of the list.
        case park
        /// From the temporary name to the new one.
        case unpark
    }

    /// The index of the item in the list the plan was made for.
    let item: Int
    let from: URL
    let to: URL
    let kind: Kind
    /// The new name differs from the old one only in what the file system does not tell
    /// apart (letter case): the rename lands on the file itself.
    let ontoItself: Bool
}

/// Works out what a set of renames collides with and in which order it can be carried out
/// (spec 09 › Name conflicts). Pure: it sees locations only and never touches a file system.
///
/// Everywhere, `sources[i]` is where item i is, and `targets[i]` where it is to go: nil when
/// the item stays (no name, skipped), the source itself when the name does not change.
struct RenamePlanner {
    /// Whether the file system takes `A.txt` and `a.txt` for the same name: in every folder,
    /// or only in the folders in `foldedFolders` (their `locationKey`s), as on a list whose
    /// items lie on several volumes.
    let foldsCase: Bool
    private let foldedFolders: Set<String>

    init(foldsCase: Bool = false) {
        self.foldsCase = foldsCase
        foldedFolders = []
    }

    init(foldedFolders: Set<String>) {
        foldsCase = false
        self.foldedFolders = foldedFolders
    }

    /// A location in the form in which the file system tells names apart.
    func key(_ url: URL) -> String {
        let plain = url.locationKey
        guard foldsCase || (!foldedFolders.isEmpty && foldedFolders.contains(url.deletingLastPathComponent().locationKey)) else { return plain }
        return plain.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Whether the item changes place or name. Byte for byte: a name that differs only in how an
    /// accented letter is written (precomposed or not) is another name, though Swift calls the
    /// two equal.
    private func moves(_ source: URL, _ target: URL?) -> Bool {
        guard let target else { return false }
        return !target.locationKey.utf8.elementsEqual(source.locationKey.utf8)
    }

    /// The items whose new name collides: with each other, with an item that stays, or with a
    /// file outside the list. `existing` holds the keys of what is in the target folders now,
    /// the sources included.
    func conflicts(sources: [URL], targets: [URL?], existing: Set<String>) -> [Int: RenameStatus] {
        // The keys are most of the work; they are made on all cores.
        let finalKeys = Parallel.map(Array(sources.indices), serialBelow: 512) { key(targets[$0] ?? sources[$0]) }
        var holders: [String: Int] = [:]
        for finalKey in finalKeys { holders[finalKey, default: 0] += 1 }
        let sourceKeys = Set(Parallel.map(sources, serialBelow: 512, key))
        var result: [Int: RenameStatus] = [:]
        for index in sources.indices where moves(sources[index], targets[index]) {
            let finalKey = finalKeys[index]
            if holders[finalKey, default: 0] > 1 {
                result[index] = .duplicate
            } else if existing.contains(finalKey) && !sourceKeys.contains(finalKey) {
                result[index] = .exists
            }
        }
        return result
    }

    /// The targets with every collision renamed away to `name (2).ext`, `name (3).ext`, …
    /// Of several items that want the same free name, the first in the list gets it.
    func autoRenamed(sources: [URL], targets: [URL?], isFolder: [Bool], existing: Set<String>) -> [URL?] {
        var targets = targets
        let moving = sources.indices.filter { moves(sources[$0], targets[$0]) }
        let movingSources = Set(moving.map { key(sources[$0]) })
        let wanted = Set(moving.compactMap { targets[$0].map(key) })
        // Taken for good: what stays where it is, in the list or outside it.
        var claimed = existing.subtracting(movingSources)
        for index in sources.indices where !moves(sources[index], targets[index]) { claimed.insert(key(sources[index])) }
        // The next number to try for a name that many items want, so that the hundredth of
        // them does not count from 2 again.
        struct Wish: Hashable {
            var key: String
            var isFolder: Bool
        }
        var nextNumber: [Wish: Int] = [:]
        for index in moving {
            guard let target = targets[index] else { continue }
            var chosen = target
            let targetKey = key(target)
            if claimed.contains(targetKey) {
                let wish = Wish(key: targetKey, isFolder: isFolder[index])
                var number = nextNumber[wish] ?? 2
                repeat {
                    chosen = RenamePlanner.numbered(target, number, isFolder: isFolder[index])
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
    /// others in turn, left where they are ("Skip these files"). An item that stays keeps its
    /// name, which another item may want: such an item is skipped as well, and so on along
    /// a chain. Works through a list of items to look at, once each.
    func skippingConflicts(sources: [URL], targets: [URL?], existing: Set<String>) -> [URL?] {
        var targets = targets
        var wanting: [String: [Int]] = [:]
        for index in sources.indices where moves(sources[index], targets[index]) { wanting[key(targets[index]!), default: []].append(index) }
        var open = Array(conflicts(sources: sources, targets: targets, existing: existing).keys)
        while let index = open.popLast() {
            guard targets[index] != nil else { continue }
            targets[index] = nil
            for other in wanting[key(sources[index])] ?? [] where targets[other] != nil { open.append(other) }
        }
        return targets
    }

    /// The longest a name can be, in UTF-8 bytes.
    static let longestName = 255

    /// `report.txt` → `report (2).txt`; a folder keeps its dots. A name that the number would make
    /// too long for the file system is shortened at its base, between two characters.
    static func numbered(_ url: URL, _ number: Int, isFolder: Bool) -> URL {
        let name = url.lastPathComponent
        let (base, ext) = isFolder ? (name, "") : FileItem.split(name)
        let tail = " (\(number))" + (ext.isEmpty ? "" : "." + ext)
        var kept = base
        while kept.utf8.count + tail.utf8.count > longestName, !kept.isEmpty { kept.removeLast() }
        return url.deletingLastPathComponent().appending(name: kept + tail)
    }

    /// The items in list order, except that those which lie inside another folder of the list
    /// (and the folders that hold some) come first, the deepest first.
    private func insideOut(_ moving: [Int], sources: [URL], sourceKeys: [String], isFolder: [Bool], cancelled: () -> Bool) -> [Int] {
        var folderKeys = Set<String>()
        var shallowest = Int.max
        for index in moving where isFolder.indices.contains(index) && isFolder[index] {
            folderKeys.insert(sourceKeys[index])
            shallowest = min(shallowest, sources[index].pathComponents.count)
        }
        guard !folderKeys.isEmpty else { return moving }
        var involved = Set<Int>()
        var holding = Set<String>()
        for (number, index) in moving.enumerated() {
            if number & 0xFFF == 0, cancelled() { return moving }
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
        guard !involved.isEmpty else { return moving }
        for index in moving where holding.contains(sourceKeys[index]) { involved.insert(index) }
        let depth = { (index: Int) in involved.contains(index) ? sources[index].pathComponents.count : -1 }
        // Stable: the items of equal depth stay in list order.
        return moving.enumerated().sorted { first, second in
            let (a, b) = (depth(first.element), depth(second.element))
            return a != b ? a > b : first.offset < second.offset
        }.map(\.element)
    }

    /// The renames in an order that works: list order, except that an item whose new name
    /// is still held by another item of the list waits for that one. A ring of such items
    /// (`1.txt` ↔ `2.txt`) is opened by moving one of them to a temporary name first.
    /// `temporaryName` gives that name for an item; it must be free in the item's folder.
    ///
    /// With `isFolder`, a folder and what lies in it that are renamed in one run are done
    /// inside out, deepest first: the items inside a folder are still where the list says they
    /// are when it is their turn, which they would not be once the folder has a new name.
    ///
    /// `cancelled` is looked at every few thousand items; a cancelled plan is cut short and must
    /// not be carried out. The keys of all items, which are most of the work, are made on all cores.
    func steps(sources: [URL], targets: [URL?], isFolder: [Bool]? = nil, temporaryName: ((Int) -> String)? = nil,
               cancelled: () -> Bool = { false }) -> [RenameStep] {
        let token = UUID().uuidString.prefix(8)
        let temporaryName = temporaryName ?? { ".afm-rename-\(token)-\($0).tmp" }
        var moving = sources.indices.filter { moves(sources[$0], targets[$0]) }
        guard !moving.isEmpty, !cancelled() else { return [] }
        let sourceKeys = Parallel.map(sources, serialBelow: 512, key)
        let targetKeys: [String?] = Parallel.map(Array(targets), serialBelow: 512) { $0.map(key) }
        if let isFolder, moving.count > 1 { moving = insideOut(moving, sources: sources, sourceKeys: sourceKeys, isFolder: isFolder, cancelled: cancelled) }
        var holder: [String: Int] = [:]
        for index in moving { holder[sourceKeys[index]] = index }

        enum State { case waiting, visiting, done }
        var states = [State](repeating: .waiting, count: sources.count)
        var parked: [Int: URL] = [:]
        var steps: [RenameStep] = []
        steps.reserveCapacity(moving.count)
        for (number, root) in moving.enumerated() where states[root] == .waiting {
            if number & 0xFFF == 0, cancelled() { return steps }
            // Followed with a stack of its own: a chain can be as long as the list.
            var stack = [root]
            while let index = stack.last {
                guard let target = targets[index] else { break }
                if states[index] == .waiting {
                    states[index] = .visiting
                    if let blocker = targetKeys[index].flatMap({ holder[$0] }), blocker != index {
                        if states[blocker] == .waiting {
                            stack.append(blocker)
                            continue
                        }
                        if states[blocker] == .visiting {
                            // The blocker waits further up for this very item: a ring.
                            let away = sources[blocker].deletingLastPathComponent().appending(name: temporaryName(blocker))
                            steps.append(RenameStep(item: blocker, from: sources[blocker], to: away, kind: .park, ontoItself: false))
                            parked[blocker] = away
                        }
                    }
                }
                stack.removeLast()
                steps.append(RenameStep(item: index, from: parked[index] ?? sources[index], to: target,
                                        kind: parked[index] == nil ? .direct : .unpark,
                                        ontoItself: targetKeys[index] == sourceKeys[index]))
                states[index] = .done
            }
        }
        return steps
    }
}
