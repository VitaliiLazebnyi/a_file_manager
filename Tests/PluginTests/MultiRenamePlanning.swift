import AFMKernel
import Foundation
import Testing

@testable import MultiRenamePlugin

/// Collisions and the order of a set of renames.
@Suite
internal struct MultiRenamePlanning {
    /// The location of `name` in `/d`.
    internal func url(_ name: String) -> URL { URL(fileURLWithPath: "/d/" + name) }

    /// The locations of `names` in `/d`; nil stays nil.
    internal func urls(_ names: [String?]) -> [URL?] { names.map { $0.map(url) } }

    /// Carries the steps out on a set of names and returns what is there afterwards; a step
    /// onto a taken name or from a missing one fails the test.
    internal func simulate(_ names: [String], _ steps: [RenameStep], foldsCase: Bool) -> [String] {
        func fold(_ name: String) -> String { foldsCase ? name.lowercased() : name }
        var present = names
        for step in steps {
            let (from, onto) = (step.from.lastPathComponent, step.destination.lastPathComponent)
            guard let index = present.firstIndex(of: from) else {
                Issue.record("\(from) is not there")
                continue
            }
            let taken = present.enumerated().contains { $0.offset != index && fold($0.element) == fold(onto) }
            #expect(!taken, "\(onto) is taken")
            #expect(step.ontoItself == (fold(from) == fold(onto) && step.kind == .direct))
            present[index] = onto
        }
        return present
    }

    /// The steps of `renames` (old name, new name or nil), the temporary names `tmp0`, `tmp1`, ….
    internal func plan(_ renames: [(String, String?)], foldsCase: Bool) -> [RenameStep] {
        RenamePlanner(foldsCase: foldsCase)
            .steps(
                sources: renames.map { url($0.0) },
                targets: urls(renames.map(\.1)),
                isFolder: [],
                temporaryName: { "tmp\($0)" },
                cancelled: { false }
            )
    }

    /// Renames that are in nobody's way are carried out in list order.
    @Test
    internal func plainRenamesKeepListOrder() {
        let steps = plan([("a", "x"), ("b", "b"), ("c", nil), ("d", "y")], foldsCase: false)
        #expect(steps.map(\.item) == [0, 3] && steps.allSatisfy { $0.kind == .direct && !$0.ontoItself })
        #expect(simulate(["a", "b", "c", "d"], steps, foldsCase: false) == ["x", "b", "c", "y"])
    }

    /// A chain of renames waits for each name to be free: the last one moves first.
    @Test
    internal func chainsWaitForTheirPlace() {
        // 1 → 2 → 3 → 4: the last has to move first.
        let steps = plan([("1", "2"), ("2", "3"), ("3", "4")], foldsCase: false)
        #expect(steps.map(\.item) == [2, 1, 0] && steps.allSatisfy { $0.kind == .direct })
        #expect(simulate(["1", "2", "3"], steps, foldsCase: false) == ["2", "3", "4"])
        let reversed = plan([("3", "4"), ("2", "3"), ("1", "2")], foldsCase: false)
        #expect(reversed.map(\.item) == [0, 1, 2])
    }

    /// Swaps and rings are opened with a temporary name, one per ring.
    @Test
    internal func swapsAndRingsGoThroughATemporaryName() {
        let swap = plan([("1.txt", "2.txt"), ("2.txt", "1.txt")], foldsCase: false)
        #expect(swap.map(\.kind) == [.park, .direct, .unpark])
        #expect(swap.map(\.item) == [0, 1, 0] && swap[0].destination.lastPathComponent == "tmp0")
        #expect(simulate(["1.txt", "2.txt"], swap, foldsCase: false) == ["2.txt", "1.txt"])

        let ring = plan([("a", "b"), ("b", "c"), ("c", "a"), ("x", "y")], foldsCase: false)
        #expect(ring.filter { $0.kind == .park }.count == 1 && ring.count == 5)
        #expect(simulate(["a", "b", "c", "x"], ring, foldsCase: false) == ["b", "c", "a", "y"])

        // Two rings and a chain that leads into one of them.
        let mixed = plan([("p", "a"), ("a", "b"), ("b", "a"), ("m", "n"), ("n", "m")], foldsCase: false)
        #expect(mixed.filter { $0.kind == .park }.count == 2)
        #expect(
            simulate(["p", "a", "b", "m", "n"], Array(mixed.dropLast(0)).filter { $0.item != 0 }, foldsCase: false) == [
                "p", "b", "a", "n", "m"
            ]
        )
    }

    /// A chain of twenty thousand renames is planned without recursion.
    @Test
    internal func aLongChainNeedsNoRecursion() {
        let count = 20_000
        let renames = (0..<count).map { (String($0), Optional(String($0 + 1))) }
        let steps = plan(renames, foldsCase: false)
        #expect(steps.count == count && steps.first?.item == count - 1 && steps.last?.item == 0)
    }

    /// A rename that changes only the letter case lands on the file itself where the volume does not tell case apart.
    @Test
    internal func caseOnlyRenames() {
        // Where case is not told apart the rename lands on the file itself…
        let folded = plan([("readme.TXT", "README.txt")], foldsCase: true)
        #expect(folded.count == 1 && folded[0].ontoItself)
        #expect(simulate(["readme.TXT"], folded, foldsCase: true) == ["README.txt"])
        // …elsewhere it is a rename like any other.
        let exact = plan([("readme.TXT", "README.txt")], foldsCase: false)
        #expect(exact.count == 1 && !exact[0].ontoItself)
        // A swap of two names that differ in case only from each other's.
        let swap = plan([("A", "b"), ("B", "a")], foldsCase: true)
        #expect(swap.map(\.kind) == [.park, .direct, .unpark])
        #expect(simulate(["A", "B"], swap, foldsCase: true) == ["b", "a"])
    }

    /// The conflicts of `renames` with each other and with the names in `existing`.
    internal func conflicts(
        _ renames: [(String, String?)],
        existing: [String],
        foldsCase: Bool
    ) -> [Int: RenameStatus] {
        let planner = RenamePlanner(foldsCase: foldsCase)
        return planner.conflicts(
            sources: renames.map { url($0.0) },
            targets: urls(renames.map(\.1)),
            existing: Set(existing.map { planner.key(url($0)) })
        )
    }

    /// Items that end with the same name, or with that of a file that stays, are conflicts.
    @Test
    internal func conflictDetection() {
        #expect(
            conflicts([("a", "x"), ("b", "x"), ("c", "y")], existing: ["a", "b", "c"], foldsCase: false) == [
                0: .duplicate, 1: .duplicate
            ]
        )
        #expect(conflicts([("a", "z"), ("b", "y")], existing: ["a", "b", "z"], foldsCase: false) == [0: .exists])
        // A name that an item of the list gives up is free; one it keeps is not.
        #expect(conflicts([("a", "b"), ("b", "c")], existing: ["a", "b"], foldsCase: false).isEmpty)
        #expect(conflicts([("a", "b"), ("b", "b")], existing: ["a", "b"], foldsCase: false) == [0: .duplicate])
        #expect(conflicts([("a", "b"), ("b", nil)], existing: ["a", "b"], foldsCase: false) == [0: .duplicate])
        #expect(conflicts([("a", "b"), ("b", "a")], existing: ["a", "b"], foldsCase: false).isEmpty)
        #expect(conflicts([("a", "sub/x")], existing: ["a", "sub/x"], foldsCase: false) == [0: .exists])
    }

    /// Where case is not told apart, names that differ only in case collide.
    @Test
    internal func conflictsAndLetterCase() {
        #expect(conflicts([("a", "A")], existing: ["a"], foldsCase: true).isEmpty)
        #expect(
            conflicts([("a", "X"), ("b", "x")], existing: ["a", "b"], foldsCase: true) == [
                0: .duplicate, 1: .duplicate
            ]
        )
        #expect(conflicts([("a", "X"), ("b", "x")], existing: ["a", "b"], foldsCase: false).isEmpty)
        #expect(conflicts([("a", "Z")], existing: ["a", "z"], foldsCase: true) == [0: .exists])
        #expect(conflicts([("a", "Z")], existing: ["a", "z"], foldsCase: false).isEmpty)
    }

    /// Auto-rename numbers the colliding names, passing over the numbers taken or wanted.
    @Test
    internal func autoRename() {
        let planner = RenamePlanner()
        func resolved(_ renames: [(String, String?)], existing: [String], folders: Set<Int>) -> [String?] {
            planner.autoRenamed(
                sources: renames.map { url($0.0) },
                targets: urls(renames.map(\.1)),
                isFolder: renames.indices.map(folders.contains),
                existing: Set(existing.map { planner.key(url($0)) })
            )
            .map { $0?.lastPathComponent }
        }
        #expect(
            resolved(
                [("a.txt", "x.txt"), ("b.txt", "x.txt"), ("c.txt", "x.txt")],
                existing: ["a.txt", "b.txt", "c.txt"],
                folders: []
            )
                == ["x.txt", "x (2).txt", "x (3).txt"]
        )
        #expect(resolved([("a.txt", "z.txt")], existing: ["a.txt", "z.txt", "z (2).txt"], folders: []) == ["z (3).txt"])
        // A number that another item of the list is about to take is passed over.
        #expect(
            resolved([("a", "x"), ("b", "x"), ("c", "x (2)")], existing: ["a", "b", "c"], folders: []) == [
                "x", "x (3)", "x (2)"
            ]
        )
        #expect(
            resolved([("a", "v1.2"), ("b", "v1.2")], existing: ["a", "b"], folders: [0, 1]) == [
                "v1.2", "v1.2 (2)"
            ]
        )
        // Unchanged and case-only renames are left alone.
        #expect(
            resolved([("a", "a"), ("b", "a"), ("c", nil)], existing: ["a", "b", "c"], folders: []) == [
                "a", "a (2)", nil
            ]
        )
        let after = resolved([("a.txt", "x.txt"), ("b.txt", "x.txt")], existing: ["a.txt", "b.txt"], folders: [])
        #expect(planner.conflicts(sources: [url("a.txt"), url("b.txt")], targets: urls(after), existing: []).isEmpty)
    }
}
