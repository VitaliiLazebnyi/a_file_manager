import Foundation
import StressKit

/// Copy, delete and move on a real tree, under random cancel / pause / resume, seed after seed.
@MainActor
internal final class LocalScenario {
    /// What the command line asked for.
    internal let settings: Settings
    /// The tree and the places its files go.
    internal let layout: Layout
    /// How long an uninterrupted run of each kind took (for choosing when to cancel).
    internal var estimate: [String: Double] = [:]
    /// The wall times of the runs, by kind.
    internal var durations: [String: [Double]] = [:]
    /// The process's threads right after each seed.
    internal var threadsAfter: [Int] = []
    /// The threads after the calibration, settled.
    internal private(set) var baselineThreads = 0
    /// The most threads seen right after a run.
    internal private(set) var maxThreads = 0

    /// The scenario that `settings` describe.
    internal init(settings: Settings) {
        self.settings = settings
        layout = Layout(settings: settings)
    }

    /// Builds the tree, calibrates, and runs every seed.
    internal func run() {
        let tree = layout
        step("build tree", limit: 900) {
            offMain { tree.prepare() }
        }
        say(
            "tree: \(layout.manifest.count) files, \(settings.folderCount) folders (+big), "
                + "\(layout.totalBytes >> 20) MB"
        )

        // Uninterrupted runs first: the rates, and how long a run takes (for choosing when to cancel).
        step("calibration: uninterrupted copy/delete/move", limit: 900) {
            calibrate()
        }
        baselineThreads = waitForThreads(atMost: 0, upTo: 6)
        say("threads at baseline (after calibration, settled 6 s): \(baselineThreads)")

        for seed in settings.seedBase..<(settings.seedBase + settings.seedCount) {
            runSeed(seed)
        }
        HangGuard.shared.disarm()
        for (kind, values) in durations.sorted(by: { $0.key < $1.key }) {
            say(
                String(
                    format: "DURATIONS %@: n=%d min=%.2fs max=%.2fs mean=%.2fs",
                    kind,
                    values.count,
                    values.min() ?? 0,
                    values.max() ?? 0,
                    values.reduce(0, +) / Double(values.count)
                )
            )
        }
    }

    /// One uninterrupted run of each kind: the rates, and the estimates for the cancels.
    private func calibrate() {
        let count = Double(layout.manifest.count)
        let copy = copyRun(seed: 0, Interference())
        estimate["copy"] = copy.wall
        say(
            String(
                format: "RATE copy: %.0f files/s, %.1f MB/s",
                count / copy.wall,
                Double(layout.totalBytes) / 1_048_576 / copy.wall
            )
        )
        let delete = deleteRun(seed: 0, Interference())
        estimate["delete"] = delete.wall
        say(String(format: "RATE delete: %.0f files/s", count / delete.wall))
        let move = moveRun(seed: 0, Interference(), back: false)
        estimate["move"] = move.wall
        say(String(format: "RATE move (half merge, same volume): %.0f files/s", count / move.wall))
        let back = moveRun(seed: 0, Interference(), back: true)
        estimate["move-back"] = back.wall
        say(
            String(
                format: "RATE move back (a third merged, rest whole-folder renames): %.0f files/s",
                count / back.wall
            )
        )
        let tree = layout
        offMain { Tree.removeQuickly(tree.moved) }
    }

    /// Notes the wall time of a run of `kind` and the threads right after it.
    internal func note(_ kind: String, _ outcome: Outcome) {
        durations[kind, default: []].append(outcome.wall)
        maxThreads = max(maxThreads, threadCount())
    }

    /// Random interference for a run of `kind`.
    internal func randomInterference(_ kind: String, _ random: inout Random) -> Interference {
        var result = Interference()
        let expected = estimate[kind] ?? 5
        // Six runs in ten are cancelled, somewhere between the start and the expected end.
        if Int.random(in: 0..<10, using: &random) < 6 {
            result.cancelAfter = Double.random(in: 0...(expected * 1.1), using: &random)
        }
        result.pauses = Int.random(in: 0..<10, using: &random) < 7
        result.cancelsOffMain = Bool.random(using: &random)
        return result
    }

    deinit {
        // Nothing to release.
    }
}
