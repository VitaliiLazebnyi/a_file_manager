import Foundation
import FuzzCore

@testable import MultiRenamePlugin

/// The items of one `planner` input: where they are, where they go, and which names are taken.
internal struct RenamePlanCase {
    /// The items, each once (by the planner's key).
    internal let sources: [URL]
    /// Each item's new place; `nil` when it stays.
    internal let targets: [URL?]
    /// Whether each item is a folder.
    internal let isFolder: [Bool]
    /// The planner's keys of the names already taken: the items and a few other files.
    internal let existing: Set<String>

    /// Reads the items from the input; the planner's keys tell them apart.
    internal init(_ choices: inout Choices, planner: RenamePlanner) {
        let count = 1 + Int(choices.byte()) % 8
        var found: [URL] = []
        var seen = Set<String>()
        for _ in 0..<count {
            let source = poolFile(inE: choices.byte() & 0x80 != 0, &choices)
            if seen.insert(planner.key(source)).inserted {
                found.append(source)
            }
        }
        var planned: [URL?] = []
        var folders: [Bool] = []
        for source in found {
            let kind = choices.byte()
            folders.append(kind & 0x40 != 0)
            switch kind % 5 {
            case 0:
                planned.append(nil)

            case 1:
                planned.append(source)

            default:
                planned.append(poolFile(inE: kind & 0x80 != 0, &choices))
            }
        }
        var taken = Set(found.map(planner.key))
        for _ in 0..<(Int(choices.byte()) % 4) {
            taken.insert(planner.key(poolFile(inE: choices.byte() & 1 != 0, &choices)))
        }
        self.init(sources: found, targets: planned, isFolder: folders, existing: taken)
    }

    /// The case made of its parts.
    internal init(sources: [URL], targets: [URL?], isFolder: [Bool], existing: Set<String>) {
        self.sources = sources
        self.targets = targets
        self.isFolder = isFolder
        self.existing = existing
    }

    /// The same items with other targets (a plan).
    internal func with(targets plan: [URL?]) -> Self {
        Self(sources: sources, targets: plan, isFolder: isFolder, existing: existing)
    }
}
