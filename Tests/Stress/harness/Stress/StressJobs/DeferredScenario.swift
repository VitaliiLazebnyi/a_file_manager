import AFMKernel
import Foundation
import LocalFileSystemPlugin
import StressKit
import TestSupport

@testable import FileOperationsPlugin

/// Moves to a target that keeps writes back (`.deferredWrites`), with commits that fail at random.
@MainActor
internal final class DeferredScenario {
    /// What the command line asked for.
    internal let settings: Settings
    /// The threads the local runs settled at (0 without them).
    internal let baselineThreads: Int
    /// The local tree that is moved.
    internal let source: URL
    /// Its files.
    internal let entries: [Entry]
    /// What the runs add up to.
    internal var totals = DeferredTotals()

    /// The scenario that `settings` describe.
    internal init(settings: Settings, baselineThreads: Int) {
        self.settings = settings
        self.baselineThreads = baselineThreads
        source = settings.root.appendingPathComponent("memsrc")
        let memFiles = settings.number("--memfiles", 3_000)
        let memFolders = settings.number("--memfolders", 60)
        let perFolder = max(1, memFiles / memFolders)
        let files = (0..<memFiles)
            .map { index in
                Entry(
                    path: String(format: "m%03d/g%05d.dat", min(memFolders - 1, index / perFolder), index),
                    index: 900_000 + index,
                    size: 8 + (index &* 131) % 1_500
                )
            }
        let tops = (0..<3).map { Entry(path: "top\($0).bin", index: 990_000 + $0, size: 300_000 + $0 * 4_096) }
        entries = files + tops
    }

    /// Sets the job's batch size and the delegate's answer to errors.
    ///
    /// Retry would ask for ever: it is answered a few times and then becomes Skip.
    private static func configuration(batch: Int, errorAnswer: ErrorChoice) -> @Sendable (FileJob) -> Void {
        let retried = Shared(0)
        return { job in
            job.deferredBatchSize = batch
            guard let recorder = job.delegate as? Recorder else {
                return
            }
            recorder.errorAnswer = errorAnswer
            if errorAnswer == .retry {
                DispatchQueue.global()
                    .asyncAfter(deadline: .now() + 0.2) {
                        recorder.errorAnswer = .skip
                        retried.update { $0 += 1 }
                    }
            }
        }
    }

    /// The move of `sources` into `/out` of `memory`, through `registry`.
    private static func moveJob(
        sources: [URL],
        memory: MemoryFileSystem,
        registry: FileSystemRegistry
    ) -> @Sendable (CancellationFlag) -> FileJob {
        { flag in
            let job = FileJob(
                kind: .move,
                sources: sources,
                target: TargetSpec(directory: memory.url("/out")),
                fileSystems: registry,
                cancellation: flag
            )
            job.options.overwrite = .overwriteAll
            return job
        }
    }

    /// Builds the source tree and runs every seed.
    internal func run() {
        let (memSource, files) = (source, entries)
        step("deferred: build source tree") {
            offMain {
                Tree.removeQuickly(memSource)
                Tree.createDirectory(memSource)
                Tree.build(at: memSource, entries: files)
            }
        }
        for seed in settings.seedBase..<(settings.seedBase + settings.memSeeds) {
            runSeed(seed)
        }
        say(totals.line)
        MainWatchdog.shared.setPhase("settle (idle)")
        let settled = waitForThreads(atMost: baselineThreads, upTo: 8)
        say("THREADS after deferred runs: settled=\(settled) baseline(local)=\(baselineThreads)")
        if !settings.keepTree {
            offMain { Tree.removeQuickly(memSource) }
        }
    }

    /// One seed: a move with random batch size, failure rate, answer and interference.
    private func runSeed(_ seed: Int) {
        var random = Random(seed: UInt64(seed) &* 0xAB_CDEF &+ 99)
        let memory = MemoryFileSystem(scheme: "dst")
        memory.capabilities = [.write, .deferredWrites]
        memory.addDirectory("/out")
        let failureRate = [0, 20, 50, 100][Int.random(in: 0..<4, using: &random)]
        let target = DeferredTarget(memory, seed: UInt64(seed), failureRate: failureRate)
        let registry = FileSystemRegistry()
        registry.register(LocalFileSystem())
        registry.register(target)
        let batch = [7, 40, 250, 10_000][Int.random(in: 0..<4, using: &random)]
        var interference = Interference()
        if Int.random(in: 0..<10, using: &random) < 4 {
            interference.cancelAfter = Double.random(in: 0...0.6, using: &random)
        }
        interference.pauses = Bool.random(using: &random)
        interference.cancelsOffMain = Bool.random(using: &random)
        let errorAnswer: ErrorChoice = [.skip, .skipAll, .abort, .retry][Int.random(in: 0..<4, using: &random)]
        MainWatchdog.shared.setPhase("deferred move")
        let sources = Tree.topLevel(source)
        let plan = JobPlan(
            label: "deferred#\(seed)",
            seed: UInt64(seed),
            interference: interference,
            limit: 120,
            configure: Self.configuration(batch: batch, errorAnswer: errorAnswer)
        )
        let outcome = JobRunner.run(plan, make: Self.moveJob(sources: sources, memory: memory, registry: registry))
        let counts = target.counts
        MainWatchdog.shared.setPhase("verify (harness)")
        let check = DeferredCase(
            seed: seed,
            source: source,
            entries: entries,
            memory: memory,
            target: target,
            counts: counts,
            failureRate: failureRate,
            batch: batch,
            cancelled: outcome.result.cancelled
        )
        let tally = offMain { check.verify() }
        say(
            describe("deferred-move", seed, outcome, interference)
                + " rate=\(failureRate)% batch=\(batch) answer=\(errorAnswer) commits ok/failed=\(counts.succeeded)/"
                + "\(counts.failed) removed=\(tally.removed) kept=\(tally.kept) errorsAsked=\(outcome.errors.count)"
        )
        totals.add(cancelled: outcome.result.cancelled, counts: counts, tally: tally)
    }

    deinit {
        // Nothing to release.
    }
}
