import FileOperationsPlugin
import StressKit

/// The runs of each kind.
extension LocalScenario {
    /// Copies the tree to the destination with `interference`, then checks both.
    internal func copyRun(seed: Int, _ interference: Interference) -> Outcome {
        let tree = layout
        let sources = offMain { Tree.topLevel(tree.source) }
        MainWatchdog.shared.setPhase("copy")
        let plan = JobPlan(
            label: "copy#\(seed)",
            seed: UInt64(seed),
            interference: interference,
            limit: 180,
            configure: nil
        )
        let outcome = JobRunner.run(plan) { flag in
            let job = FileJob(
                kind: .copy,
                sources: sources,
                target: TargetSpec(directory: tree.destination),
                fileSystems: tree.fileSystems,
                cancellation: flag
            )
            job.options.overwrite = .overwriteAll
            return job
        }
        say(describe("copy", seed, outcome, interference))
        note("copy", outcome)
        MainWatchdog.shared.setPhase("verify (harness)")
        offMain { tree.verifyCopy(seed: seed, outcome: outcome, sources: sources) }
        return outcome
    }

    /// Deletes what is at the destination with `interference`, then checks both trees.
    internal func deleteRun(seed: Int, _ interference: Interference) -> Outcome {
        let tree = layout
        let sources = offMain { Tree.topLevel(tree.destination) }
        let before = offMain { Tree.survey(tree.destination, entries: tree.manifest) }
        MainWatchdog.shared.setPhase("delete")
        let plan = JobPlan(
            label: "delete#\(seed)",
            seed: UInt64(seed) &* 31 &+ 7,
            interference: interference,
            limit: 180,
            configure: nil
        )
        let outcome = JobRunner.run(plan) { flag in
            FileJob(
                kind: .delete(toTrash: false),
                sources: sources,
                target: nil,
                fileSystems: tree.fileSystems,
                cancellation: flag
            )
        }
        say(describe("delete", seed, outcome, interference))
        note("delete", outcome)
        MainWatchdog.shared.setPhase("verify (harness)")
        offMain { tree.verifyDelete(seed: seed, outcome: outcome, before: before) }
        return outcome
    }

    /// Moves the tree to the moved place, or `back`, with `interference`, then checks both ends.
    internal func moveRun(seed: Int, _ interference: Interference, back: Bool) -> Outcome {
        let tree = layout
        let (from, destination) = back ? (tree.moved, tree.source) : (tree.source, tree.moved)
        let kind = back ? "move-back" : "move"
        offMain { tree.prepareMove(seed: seed, back: back) }
        let sources = offMain { Tree.topLevel(from) }
        MainWatchdog.shared.setPhase(kind)
        let plan = JobPlan(
            label: "\(kind)#\(seed)",
            seed: UInt64(seed) &* 131 &+ (back ? 5 : 3),
            interference: interference,
            limit: 180,
            configure: nil
        )
        let outcome = JobRunner.run(plan) { flag in
            let job = FileJob(
                kind: .move,
                sources: sources,
                target: TargetSpec(directory: destination),
                fileSystems: tree.fileSystems,
                cancellation: flag
            )
            job.options.overwrite = .overwriteAll
            return job
        }
        say(describe(kind, seed, outcome, interference))
        note(kind, outcome)
        MainWatchdog.shared.setPhase("verify (harness)")
        offMain { tree.verifyMove(seed: seed, kind: kind, outcome: outcome, back: back) }
        return outcome
    }
}
