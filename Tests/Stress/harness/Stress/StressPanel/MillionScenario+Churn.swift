import AFMKernel
import Darwin
import Foundation
import StressKit

@testable import AFMShell

/// Scenario 1, step 8: quiet reloads while another program creates and deletes files.
extension MillionScenario {
    /// A thread that, until `stop` is set, makes 50 files in `folder`, deletes them again, and counts
    /// both in `counter`.
    nonisolated internal static func churnThread(in folder: URL, stop: CancellationFlag, counter: Counter) -> Thread {
        Thread {
            var round = 0
            while !stop.isCancelled {
                let names = (0..<50).map { folder.appendingPathComponent("zz-churn-\(round)-\($0).tmp").path }
                for name in names {
                    close(open(name, O_CREAT | O_WRONLY, 0o644))
                }
                usleep(20_000)
                for name in names {
                    unlink(name)
                }
                counter.add(100)
                round += 1
                usleep(20_000)
            }
        }
    }

    /// 8: 200 quiet reloads while another "program" creates and deletes files; the watcher is live too.
    internal func churnReloads() {
        let churnStop = CancellationFlag()
        let churned = Counter()
        let churn = Self.churnThread(in: big, stop: churnStop, counter: churned)
        step("8 200 quiet reloads + churn + watcher (<=90 s)", limit: 400) {
            churn.start()
            reloadWhileChurning(churnStop: churnStop, churned: churned)
            check(pump(upTo: 200) { !left.isLoading }, "8: reloading did not settle after the churn stopped")
            // Whatever the churn left behind goes; then the list must match the folder again.
            usleep(100_000)
            MainWatchdog.shared.setPhase("(harness clean-up, not the app)")
            let names = try? FileManager.default.contentsOfDirectory(atPath: big.path)
            if let leftovers = names?.filter({ $0.hasPrefix("zz-churn-") }) {
                for name in leftovers {
                    unlink(big.appendingPathComponent(name).path)
                }
            }
        }
    }

    /// Asks for 200 quiet reloads 0.25 s apart (for up to 90 s), then stops the churn and prints what
    /// happened.
    internal func reloadWhileChurning(churnStop: CancellationFlag, churned: Counter) {
        var reads = 0
        var wasLoading = left.isLoading
        var versions = Set<Int>([left.model.listVersion])
        var asked = 0
        let started = now()
        var nextAsk = started
        _ = pump(upTo: 90) {
            let loading = left.isLoading
            if loading, !wasLoading {
                reads += 1
            }
            wasLoading = loading
            versions.insert(left.model.listVersion)
            if asked < 200, now() >= nextAsk {
                left.reload(focus: nil, quietly: true, completion: nil)
                asked += 1
                nextAsk = now() + 0.25
            }
            return asked >= 200 && !loading
        }
        churnStop.cancel()
        say(
            String(
                format: "   asked=%d quiet reloads in %.1f s; readings started=%d; list versions seen=%d; churn ops=%d",
                asked,
                now() - started,
                reads,
                versions.count,
                churned.count
            )
        )
    }

    /// 8b: a final reload; the list must equal the folder.
    internal func finalReload() {
        step("8b final quiet reload, list equals folder", limit: 300) {
            pump(for: 1.5)
            var ended = false
            _ = pump(upTo: 120) { !left.isLoading }
            left.reload(focus: nil, quietly: false) { ended = true }
            check(pump(upTo: 200) { ended && !left.isLoading }, "8b: final reload did not end")
            check(
                left.model.items.count == total,
                "8b: after the churn the panel lists \(left.model.items.count), the folder has \(total)"
            )
            check(!left.model.items.contains { $0.name.hasPrefix("zz-churn-") }, "8b: churn files still listed")
        }
    }
}
