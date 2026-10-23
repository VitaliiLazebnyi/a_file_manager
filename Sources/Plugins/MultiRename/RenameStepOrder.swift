import AFMKernel
import Foundation

/// Puts the renames of a plan in an order that works: each item after the one that still holds its
/// new name; a ring of such items (`1.txt` ↔ `2.txt`) is opened by moving one of them to a temporary
/// name first (`RenamePlanner.steps`).
internal struct RenameStepOrder {
    private enum State {
        case done
        case visiting
        case waiting
    }

    private let sources: [URL]
    private let destinations: [URL]
    private let sourceKeys: [String]
    private let targetKeys: [String?]
    private let temporaryName: (Int) -> String
    private var holder: [String: Int] = [:]
    private var states: [State]
    private var parked: [Int: URL] = [:]
    private var steps: [RenameStep] = []

    /// The order of the items at `sources`, which go to `destinations`; the keys are the planner's, nil
    /// for an item that stays. `temporaryName` gives the name an item is parked under.
    internal init(
        sources: [URL],
        destinations: [URL],
        sourceKeys: [String],
        targetKeys: [String?],
        temporaryName: @escaping (Int) -> String
    ) {
        self.sources = sources
        self.destinations = destinations
        self.sourceKeys = sourceKeys
        self.targetKeys = targetKeys
        self.temporaryName = temporaryName
        states = [State](repeating: .waiting, count: sources.count)
    }

    /// The steps of the items in `moving`, taken in that order as far as their names allow.
    ///
    /// `cancelled` is looked at every few thousand items; a cancelled order is cut short.
    internal mutating func steps(for moving: [Int], cancelled: () -> Bool) -> [RenameStep] {
        for index in moving {
            holder[sourceKeys[index]] = index
        }
        steps.reserveCapacity(moving.count)
        for (number, root) in moving.enumerated() where states[root] == .waiting {
            if number & 0xFFF == 0, cancelled() {
                return steps
            }
            follow(root)
        }
        return steps
    }

    /// The steps of `root` and of the chain of items that hold the names it waits for, the last of
    /// the chain first; followed with a stack of its own, as a chain can be as long as the list.
    private mutating func follow(_ root: Int) {
        var stack = [root]
        while let index = stack.last {
            if states[index] == .waiting {
                states[index] = .visiting
                if let blocker = targetKeys[index].flatMap({ holder[$0] }), blocker != index {
                    if states[blocker] == .waiting {
                        stack.append(blocker)
                        continue
                    }
                    if states[blocker] == .visiting {
                        // The blocker waits further up for this very item: a ring.
                        park(blocker)
                    }
                }
            }
            stack.removeLast()
            steps.append(
                RenameStep(
                    item: index,
                    from: parked[index] ?? sources[index],
                    destination: destinations[index],
                    kind: parked[index] == nil ? .direct : .unpark,
                    ontoItself: targetKeys[index] == sourceKeys[index]
                )
            )
            states[index] = .done
        }
    }

    /// Moves `item` out of the way, to a temporary name in its folder.
    private mutating func park(_ item: Int) {
        let away = sources[item].deletingLastPathComponent().appending(name: temporaryName(item))
        steps.append(RenameStep(item: item, from: sources[item], destination: away, kind: .park, ontoItself: false))
        parked[item] = away
    }
}
