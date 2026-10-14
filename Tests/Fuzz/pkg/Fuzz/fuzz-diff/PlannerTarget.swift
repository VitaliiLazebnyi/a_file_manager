import Foundation
import FuzzCore

@testable import AFMKernel
@testable import MultiRenamePlugin

// MARK: planner

/// Names the planner's items and targets are made of: case and normalisation twins, counters, extensions.
internal let kNamePool = [
    "a", "A", "b", "B", "c", "é", "e\u{301}", "a (2)", "a.txt", "A.TXT", "a (2).txt", "b.d", "x y", "É"
]

/// The seeds of `planner`.
@MainActor
internal func plannerSeeds() -> [[UInt8]] {
    [
        [0, 3, 0, 2, 4, 1, 3, 2, 1, 3, 0, 0], [1, 2, 0, 1, 2, 2, 2, 1, 5, 6],
        [2, 5, 0, 1, 2, 3, 4, 2, 3, 3, 4, 3, 5, 2, 1, 4, 0, 9, 9],
        [5, 4, 8, 9, 10, 0, 2, 1, 2, 10, 2, 9, 0, 0, 3, 7, 7]
    ]
}

/// A file in /d or /e (as `choices` says) with a name from the pool.
internal func poolFile(inE: Bool, _ choices: inout Choices) -> URL {
    let folder = URL(fileURLWithPath: inE ? "/e" : "/d", isDirectory: true)
    return folder.appending(name: kNamePool[Int(choices.byte()) % kNamePool.count])
}

/// The paths of a plan, `-` for an item that stays.
internal func planText(_ plan: [URL?]) -> String {
    "\(plan.map { $0?.path ?? "-" })"
}

/// Carries the plan's steps out on a set of names: each step finds its item, lands on a free name, and every item
/// ends where the plan wants it.
internal func checkSteps(_ planner: RenamePlanner, _ plan: RenamePlanCase, _ detail: String) {
    let (sources, targets) = (plan.sources, plan.targets)
    var names = plan.existing
    var place = sources.map(planner.key)
    let steps = planner.steps(sources: sources, targets: targets) { ".tmp-\($0)" }
    let stepsDetail =
        detail + " plan \(planText(targets)) steps \(steps.map { "\($0.item):\($0.from.path)>\($0.to.path)" })"
    for step in steps {
        let (from, onto) = (planner.key(step.from), planner.key(step.to))
        fzCheck(place[step.item] == from && names.contains(from), "planner-step-source-missing", stepsDetail)
        fzCheck(step.ontoItself == (from == onto), "planner-onto-itself-flag", stepsDetail)
        fzCheck(from == onto || !names.contains(onto), "planner-step-onto-existing", stepsDetail)
        names.remove(from)
        names.insert(onto)
        place[step.item] = onto
    }
    for index in sources.indices {
        let want = targets[index].map(planner.key) ?? planner.key(sources[index])
        // A change of case only on a folding file system still is a rename to carry out.
        if let target = targets[index], target.locationKey != sources[index].locationKey {
            fzCheck(place[index] == want, "planner-item-not-at-target", stepsDetail)
        } else {
            fzCheck(place[index] == planner.key(sources[index]), "planner-staying-item-moved", stepsDetail)
        }
    }
}

/// The planner on a few items: the conflict-free plans have no conflicts, and the steps carry any plan out.
@MainActor
internal func runPlanner(_ bytes: [UInt8]) {
    var choices = Choices(bytes)
    let flags = choices.byte()
    let folds = flags & 1 != 0
    let mode = Int(flags >> 1) % 3  // 0: as it is (when free of conflicts), 1: auto rename, 2: skip
    let planner =
        folds
        ? RenamePlanner(foldsCase: true)
        : (flags & 0x40 != 0 ? RenamePlanner(foldedFolders: ["file:///d"]) : RenamePlanner())
    let item = RenamePlanCase(&choices, planner: planner)
    let (sources, targets, existing) = (item.sources, item.targets, item.existing)
    let detail =
        "folds \(folds) mode \(mode) sources \(sources.map(\.path)) targets \(planText(targets))"
        + " existing \(existing.sorted())"
    var plan = targets
    if mode == 1 {
        plan = planner.autoRenamed(sources: sources, targets: targets, isFolder: item.isFolder, existing: existing)
    }
    if mode == 2 {
        plan = planner.skippingConflicts(sources: sources, targets: targets, existing: existing)
    }
    let conflicts = planner.conflicts(sources: sources, targets: plan, existing: existing)
    if mode != 0 {
        fzCheck(
            conflicts.isEmpty,
            mode == 1 ? "planner-autorename-leaves-conflict" : "planner-skip-leaves-conflict",
            detail + " plan \(planText(plan)) conflicts \(conflicts)"
        )
    }
    guard conflicts.isEmpty else {
        return
    }
    checkSteps(planner, item.with(targets: plan), detail)
}

/// The `planner` target.
@MainActor
internal func plannerTarget() -> FuzzTarget {
    FuzzTarget("planner", maxLen: 256, seeds: plannerSeeds, run: runPlanner)
}
