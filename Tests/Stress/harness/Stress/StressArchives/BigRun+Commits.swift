import Foundation
import StressKit

@testable import ArchivesPlugin

/// The checks after every commit: another program, the directory, and a fresh reader of the program's own.
extension BigRun {
    /// `unzip -tq`: every member's CRC, by another program.
    internal func checkWithUnzip(batch: Int) {
        let started = now()
        let test = tool("/usr/bin/unzip", ["-tq", archive.path])
        Counter.shared.time("unzip -tq", now() - started)
        if test.status != 0 || !test.output.contains("No errors detected") {
            Findings.shared.violation(
                "ARCHIVE INVALID after a commit (unzip -tq)",
                "batch \(batch): status \(test.status): \(test.output.suffix(300))"
            )
        }
    }

    /// `zipinfo`: the directory lists what was added, and the totals can be read.
    internal func checkWithZipinfo(batch: Int, added: [Probe]) {
        let info = tool("/usr/bin/zipinfo", ["-1", archive.path, "added/batch\(String(format: "%04d", batch))/*"])
        let listed = Set(info.output.split(separator: "\n").map(String.init))
        for probe in added where !listed.contains(probe.path) {
            Findings.shared.violation(
                "zipinfo does not list a committed member",
                "\(probe.path) (status \(info.status))"
            )
        }
        let totals = tool("/usr/bin/zipinfo", ["-t", archive.path])
        if totals.status != 0 {
            Findings.shared.violation(
                "zipinfo -t failed after a commit",
                "batch \(batch): \(totals.output.suffix(200))"
            )
        }
    }

    /// The program's own reader, from scratch: counts, and the bytes of what was just added and of an old probe.
    internal func checkWithFreshReader(batch: Int, added: [Probe], expectedFiles: Int, random: inout Random) {
        let started = now()
        let fresh = Bench(flushDelay: nil)
        do {
            let opened = try fresh.store.archive(at: archive, cancellation: nil)
            let files = opened.entries.filter { !$0.isDirectory }.count
            if files != expectedFiles {
                Findings.shared.violation(
                    "fresh reader counts other members than were committed",
                    "batch \(batch): \(files) instead of \(expectedFiles)"
                )
            }
            for probe in added {
                let got = fresh.readAll(fresh.inside(archive, probe.path))
                if got.data != probe.data {
                    Findings.shared.violation(
                        "COMMITTED MEMBER READS BACK WRONG (fresh reader)",
                        "\(probe.path): \(String(describing: got.error))"
                    )
                }
            }
            let old = probes[Int.random(in: 0..<probes.count, using: &random)]
            if fresh.readAll(fresh.inside(archive, old.path)).data != old.data {
                Findings.shared.violation("old member damaged after a commit (fresh reader)", old.path)
            }
        } catch {
            Findings.shared.violation(
                "ARCHIVE UNREADABLE by a fresh reader after a commit",
                "batch \(batch): \(error.localizedDescription)"
            )
        }
        fresh.store.close()
        Counter.shared.time("fresh reader open + verify", now() - started)
    }
}
