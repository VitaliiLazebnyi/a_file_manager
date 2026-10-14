import AFMKernel
import Darwin
import Foundation
import StressKit

@testable import AFMShell

/// Scenario 8: a flood of changes in a watched folder.
@MainActor
internal final class FloodScenario {
    /// Files in the watched folder before the flood.
    internal let files: Int
    /// Operations per second the flood aims at.
    internal let rate: Int
    /// How long the flood lasts.
    internal let seconds: Double
    /// The watched folder.
    internal let watched: URL
    /// The running program.
    internal let app: Running
    /// The panel that shows the watched folder.
    internal let left: PanelViewController
    /// Threads after start-up, when idle.
    internal let baseline: Int

    /// Makes the folders and starts the program: `arguments[2]` is the work directory, then optionally
    /// the files, the operations per second and the seconds.
    internal init(arguments: [String]) {
        let work = URL(fileURLWithPath: arguments[2], isDirectory: true)
        files = arguments.count > 3 ? Self.number(arguments[3]) : 20_000
        rate = arguments.count > 4 ? Self.number(arguments[4]) : 5_000
        seconds = arguments.count > 5 ? Self.duration(arguments[5]) : 20
        let small = work.appendingPathComponent("small")
        let folder = work.appendingPathComponent("flood")
        watched = folder
        MainWatchdog.shared.setPhase("(harness set-up, not the app)")
        makeSmall(small, files: 40)
        Self.makeWatched(folder, files: files)
        app = step("start-up") { () -> Running in
            let started = Running(left: folder, right: small, home: small, providers: [])
            check(started.settle(), "start-up did not settle")
            return started
        }
        left = app.left
        step("idle baseline (2 s)") { pump(for: 2) }
        baseline = threadCount()
        say("   watched folder: \(left.model.items.count) rows")
    }

    /// `text` as a whole number; stops the process when it is none.
    private static func number(_ text: String) -> Int {
        guard let value = Int(text) else {
            preconditionFailure("not a whole number: \(text)")
        }
        return value
    }

    /// `text` as a number of seconds; stops the process when it is none.
    private static func duration(_ text: String) -> Double {
        guard let value = Double(text) else {
            preconditionFailure("not a number of seconds: \(text)")
        }
        return value
    }

    /// Makes `folder` anew with `files` empty files.
    private static func makeWatched(_ folder: URL, files: Int) {
        let manager = FileManager.default
        try? manager.removeItem(at: folder)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            preconditionFailure("cannot make \(folder.path): \(error)")
        }
        for index in 0..<files {
            let path = folder.appendingPathComponent(String(format: "base%06d.dat", index)).path
            close(open(path, O_CREAT | O_WRONLY, 0o644))
        }
    }

    /// Runs the script and ends the process.
    internal func run() -> Never {
        let footprintBefore = footprintMB()
        let stop = CancellationFlag()
        let operations = Counter()
        let flooder = Flooder.thread(in: watched, rate: rate, stop: stop, counter: operations)
        var reads = 0
        var versions = Set<Int>([left.model.listVersion])
        let cpuBefore = cpuSeconds()
        let name = String(format: "flood: %d ops/s for %.0f s in %d-file folder", rate, seconds, files)
        step(name, limit: seconds + 120) {
            flooder.start()
            var wasLoading = false
            let end = now() + seconds
            _ = pump(upTo: seconds + 5) {
                let loading = left.isLoading
                if loading, !wasLoading {
                    reads += 1
                }
                wasLoading = loading
                versions.insert(left.model.listVersion)
                return now() >= end
            }
            stop.cancel()
        }
        let cpuFlood = cpuSeconds() - cpuBefore
        let format =
            "   achieved %d operations (%.0f/s); readings of the folder started=%d; list versions=%d; "
            + "process CPU %.1f s over %.0f s (%.0f%% of one core, includes the flooding thread itself)"
        say(
            String(
                format: format,
                operations.count,
                Double(operations.count) / seconds,
                reads,
                versions.count,
                cpuFlood,
                seconds,
                cpuFlood / seconds * 100
            )
        )
        settleAndCompare(footprintBefore: footprintBefore)
        MainWatchdog.shared.setPhase("(harness clean-up, not the app)")
        try? FileManager.default.removeItem(at: watched)
        finish("scenario 8: watcher flood", baseline: baseline, app: app)
    }

    /// Lets the panel settle after the flood and checks that it lists what the folder holds.
    internal func settleAndCompare(footprintBefore: Double) {
        step("settle after flood (3 s + until quiet)", limit: 120) {
            pump(for: 3)
            check(pump(upTo: 100) { !left.isLoading }, "8: panel still reading 100 s after the flood")
            pump(for: 1.5)
            _ = pump(upTo: 100) { !left.isLoading }
        }
        let onDisk = Set((try? FileManager.default.contentsOfDirectory(atPath: watched.path)) ?? [])
        let shown = Set(left.model.items.map(\.name))
        let missing = onDisk.subtracting(shown).count
        let stale = shown.subtracting(onDisk).count
        check(
            onDisk == shown,
            "8: after the flood the panel shows \(shown.count) names, the folder has \(onDisk.count) "
                + "(missing \(missing), stale \(stale))"
        )
        say(
            String(
                format:
                    "   after settle: panel rows=%d, folder entries=%d, equal=%@; footprint before=%.0fMB after=%.0fMB",
                shown.count,
                onDisk.count,
                "\(onDisk == shown)",
                footprintBefore,
                footprintMB()
            )
        )
    }

    deinit {
        // Nothing to release.
    }
}
