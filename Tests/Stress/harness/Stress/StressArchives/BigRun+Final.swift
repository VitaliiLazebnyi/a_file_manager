import Foundation
import StressKit

@testable import ArchivesPlugin

/// The steps after the concurrent stage: final checks, a hazard measurement, leaks, threads, leftovers.
extension BigRun {
    /// Whether `line` of the leaks report is one of its totals.
    private static func isLeaksSummary(_ line: Substring) -> Bool {
        line.contains("total leaked bytes") || line.contains("Physical footprint") || line.contains("nodes malloced")
    }

    /// Waits for the delayed writes, then checks the archive and every member that was ever committed.
    @MainActor
    internal func finalChecks(_ members: Members) {
        step("after: wait for delayed writes, final checks", limit: 300) {
            pump(for: 2.5)
            offMain { [self] in
                if let open = bench.store.openArchive(at: archive), open.hasPendingChanges {
                    Findings.shared.violation("changes still pending after the last commit", "")
                }
                let test = tool("/usr/bin/unzip", ["-tq", archive.path])
                if test.status != 0 {
                    Findings.shared.violation("ARCHIVE INVALID at the end (unzip -tq)", String(test.output.suffix(300)))
                }
                say("final unzip -tq: \(trimmed(test.output).suffix(200))")
                say("final zipinfo -t: \(trimmed(tool("/usr/bin/zipinfo", ["-t", archive.path]).output))")
                // Every member that was ever committed, through the long-lived store.
                let all = members.all
                var wrong = 0
                for probe in all where bench.readAll(bench.inside(archive, probe.path)).data != probe.data {
                    wrong += 1
                }
                if wrong > 0 {
                    Findings.shared.violation(
                        "members read back wrong at the end (long-lived store)",
                        "\(wrong) of \(all.count)"
                    )
                }
                say("final: \(all.count) probe/added members verified through the long-lived store, wrong=\(wrong)")
            }
        }
    }

    /// Measures what a main-thread caller of `item(at:)` waits while another thread opens the archive.
    @MainActor
    internal func hazard() {
        step("hazard: item(at:) on main while another thread opens the same archive", limit: 300) {
            // Not something the harness saw the shell do; it measures what a main-thread caller would wait.
            let fresh = Bench(flushDelay: nil)
            let opened = Locked(false)
            let thread = Thread { [archive] in
                _ = try? fresh.store.archive(at: archive)
                opened.value = true
            }
            thread.start()
            usleep(20_000)
            let started = now()
            let found = fresh.zip.item(at: fresh.inside(archive, "dir0001/f000500.txt"))
            let format =
                "HAZARD item(at:) without a flag, called on main 20 ms after another thread began opening the "
                + "archive: returned after %.0f ms (found=%@, opener done=%@)"
            say(
                String(
                    format: format,
                    (now() - started) * 1_000,
                    found == nil ? "no" : "yes",
                    opened.value ? "yes" : "no"
                )
            )
            pump(upTo: 60) { opened.value }
            fresh.store.close()
        }
    }

    /// Runs `leaks(1)` on this process and keeps its report in the results folder.
    @MainActor
    internal func leaks() {
        step("leaks(1) on this process", limit: 900) {
            let report: String = offMain { tool("/usr/bin/leaks", ["\(getpid())"]).output }
            let lines = report.split(separator: "\n", omittingEmptySubsequences: false)
            for line in lines where Self.isLeaksSummary(line) {
                say("LEAKS " + line)
            }
            try? report.write(toFile: options.results + "/archives-leaks.txt", atomically: true, encoding: .utf8)
        }
    }

    /// Waits for the threads to settle and checks that the program's own named threads are gone.
    @MainActor
    internal func settle(baselineThreads: Int) {
        MainWatchdog.shared.setPhase("settle (idle)")
        let settled = waitForThreads(atMost: baselineThreads, upTo: 8)
        say("THREADS baseline=\(baselineThreads) settled(<=8s)=\(settled)")
        // The system's queue threads come and go by a few; what must be gone are the program's own named threads.
        let own = threadCount(named: "AFM.", except: ".watch")
        say("THREADS by name: " + threadNames())
        if settled > baselineThreads + 2, own > 0 {
            Findings.shared.violation(
                "threads did not return to baseline",
                "\(settled) vs \(baselineThreads), \(own) of the program's own: " + threadNames()
            )
        }
    }

    /// Checks that no file was left next to the archive.
    internal func checkLeftovers() {
        let directory = options.directory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let leftovers = names.filter { name in
            name != "big.zip" && name != "deep.zip" && name != "probe.tsv" && name != "probe-ref"
                && !name.hasSuffix(".pristine.zip")
        }
        if !leftovers.isEmpty {
            Findings.shared.violation("files left next to the archive", leftovers.prefix(5).joined(separator: ", "))
        }
    }
}
