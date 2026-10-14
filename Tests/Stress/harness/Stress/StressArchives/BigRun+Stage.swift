import AFMKernel
import Foundation
import StressKit

/// The concurrent stage: readers, one lister and one adder that commits, all at once.
extension BigRun {
    /// Runs the readers, the lister and the adder for the stage's duration; returns the members known then.
    @MainActor
    internal func runConcurrentStage() -> Members {
        let stop = CancellationFlag()
        let members = Members(probes: probes, files: options.expectedEntries + probes.count)
        let threads = ThreadGroup()
        let cancelQueue = DispatchQueue(label: "stress.cancel", attributes: .concurrent)

        MainWatchdog.shared.setPhase("concurrent: 16 readers + adder/commit + lister")
        HangGuard.shared.arm("concurrent archive stage", seconds: options.duration + 240)
        let stageStart = now()
        let (cpuBefore, footprintBefore) = (cpuSeconds(), footprintMB())

        for reader in 0..<options.readerCount {
            threads.launch("Stress.Reader\(reader)") { [self] in
                readerLoop(reader, members: members, stop: stop, cancelQueue: cancelQueue)
            }
        }
        threads.launch("Stress.Lister") { [self] in listerLoop(stop: stop) }
        threads.launch("Stress.Adder") { [self] in
            adderLoop(members: members, stop: stop, stageStart: stageStart)
        }

        pump(for: options.duration)
        stop.cancel()
        waitForStage(threads)
        let wall = now() - stageStart
        let cpu = cpuSeconds() - cpuBefore
        let format =
            "STAGE concurrent: wall=%.1fs cpu=%.1fs (%.1f cores) footprint %.0f->%.0f MB peakRSS=%.0f MB "
            + "threads=%d load=%.1f"
        say(
            String(
                format: format,
                wall,
                cpu,
                cpu / wall,
                footprintBefore,
                footprintMB(),
                peakRSSMB(),
                threadCount(),
                loadAverage()
            )
        )
        return members
    }

    /// Waits up to 180 s for the stage's threads to end; a sample of the process when they do not.
    @MainActor
    private func waitForStage(_ threads: ThreadGroup) {
        MainWatchdog.shared.setPhase("concurrent: waiting for the threads to end")
        let ended = pump(upTo: 180) { threads.running == 0 }
        if !ended {
            Findings.shared.violation(
                "THREADS DID NOT END (deadlock?)",
                "\(threads.running) of \(threads.count) still running 180 s after stop; see the hang sample"
            )
            HangGuard.shared.arm("archive threads did not end", seconds: 0.1)
            pump(for: 30)
        }
        HangGuard.shared.disarm()
    }
}
