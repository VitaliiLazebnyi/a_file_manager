import AFMKernel
import Foundation
import StressKit

@testable import AFMShell

/// Pauses, resumes and cancels the running job from a thread of its own, at random moments.
internal final class Controller: Sendable {
    /// What to do to the job.
    internal let interference: Interference
    /// Seeds the random moments.
    internal let seed: UInt64
    /// Ends the controller's thread.
    internal let stop = CancellationFlag()
    /// How often the job was paused.
    internal let pauses = Shared(0)
    /// Whether the cancel was sent.
    internal let cancelSent = Shared(false)
    /// The job's own cancellation flag, once the job has started: what a cancel off the main thread sets.
    internal let jobFlag = Shared<CancellationFlag?>(nil)

    /// A controller that does `interference`, at moments chosen by `seed`.
    internal init(interference: Interference, seed: UInt64) {
        self.interference = interference
        self.seed = seed
    }

    /// Starts the controller's thread; it runs until `stop` is set.
    internal func start() {
        let thread = Thread { [self] in
            run()
        }
        thread.name = "Stress.Controller"
        thread.start()
    }

    /// The controller's thread.
    private func run() {
        var random = Random(seed: seed)
        let begun = now()
        var paused = false
        while !stop.isCancelled {
            usleep(UInt32.random(in: 500...12_000, using: &random))
            if stop.isCancelled {
                break
            }
            if let cancelAt = interference.cancelAfter, now() - begun >= cancelAt, !cancelSent.value {
                sendCancel()
                continue
            }
            guard interference.pauses else {
                continue
            }
            paused = nextPause(paused, &random)
        }
    }

    /// Cancels the job: through the main thread, or here, on the job's own cancellation flag.
    ///
    /// The flag is what JobHandle.cancel sets too; the job's pause gate looks at it while it waits.
    /// A job whose flag is not known yet is tried again at the next moment.
    private func sendCancel() {
        guard interference.cancelsOffMain else {
            cancelSent.value = true
            DispatchQueue.main.async {
                MainActor.assumeIsolated { JobRunner.service.cancelCurrent() }
            }
            return
        }
        guard let flag = jobFlag.value else {
            return
        }
        cancelSent.value = true
        flag.cancel()
    }

    /// Pauses or resumes the job at random; whether it is paused afterwards.
    private func nextPause(_ paused: Bool, _ random: inout Random) -> Bool {
        if paused {
            // Resume after a short while.
            guard Int.random(in: 0..<3, using: &random) > 0 else {
                return true
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { JobRunner.service.setPaused(false) }
            }
            return false
        }
        guard Int.random(in: 0..<12, using: &random) == 0 else {
            return false
        }
        pauses.update { $0 += 1 }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { JobRunner.service.setPaused(true) }
        }
        return true
    }

    deinit {
        // Nothing to release.
    }
}
