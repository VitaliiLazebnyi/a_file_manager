import AFMKernel
import Foundation
import StressKit

/// The steps before the concurrent stage: opening, listing, asking on the main thread, reading once.
extension BigRun {
    /// Opens the archive and lists its root the way a panel does.
    @MainActor
    internal func openAndList() {
        let before = footprintMB()
        step("open + list root (panel path)", limit: 300) {
            let loaded = panelLoad(bench, root)
            say(
                String(
                    format: "LOAD root: first piece %.3fs, complete %.3fs, %d items, error=%@",
                    loaded.first,
                    loaded.total,
                    loaded.count,
                    "\(String(describing: loaded.error))"
                )
            )
            if loaded.count != folders + 1 {
                Findings.shared.violation(
                    "root listing has the wrong number of items",
                    "\(loaded.count) instead of \(folders + 1)"
                )
            }
        }
        let members = options.expectedEntries + 64
        say(
            String(
                format: "MEMORY open archive with %d members: footprint %.0f MB -> %.0f MB (%.0f bytes per member)",
                members,
                before,
                footprintMB(),
                (footprintMB() - before) * 1_048_576 / Double(members)
            )
        )
    }

    /// Lists the root again, with the archive open.
    @MainActor
    internal func listAgain() {
        step("list root again (archive open)") {
            let loaded = panelLoad(bench, root)
            say(String(format: "LOAD root again: first %.3fs complete %.3fs", loaded.first, loaded.total))
        }
    }

    /// Lists one folder of 500 the way a panel does.
    @MainActor
    internal func listOneFolder() {
        step("list one folder of 500 (panel path)") {
            let loaded = panelLoad(bench, bench.inside(archive, "dir0001"))
            say(
                String(
                    format: "LOAD dir0001: first %.4fs complete %.4fs, %d items",
                    loaded.first,
                    loaded.total,
                    loaded.count
                )
            )
            if loaded.count != 500 {
                Findings.shared.violation("folder listing has the wrong number of items", "dir0001: \(loaded.count)")
            }
        }
    }

    /// Lists every folder, one after the other, on one thread.
    @MainActor
    internal func listEveryFolder() {
        step("list every folder (\(folders) listings, 1 thread)", limit: 600) {
            let total: Int = offMain { [self] in
                var total = 0
                for folder in 0..<folders {
                    total += (try? bench.zip.list(folderURL(folder), showHidden: true).count) ?? 0
                }
                return total
            }
            if total != options.expectedEntries {
                Findings.shared.violation(
                    "listings of all folders do not add up",
                    "\(total) instead of \(options.expectedEntries)"
                )
            }
        }
    }

    /// Lists every folder, on all cores at once.
    @MainActor
    internal func listEveryFolderAtOnce() {
        step("list every folder (16 threads at once)", limit: 600) {
            let total: Int = offMain { [self] in
                let sum = Locked(0)
                DispatchQueue.concurrentPerform(iterations: folders) { folder in
                    let count = (try? bench.zip.list(folderURL(folder), showHidden: true).count) ?? 0
                    sum.update { $0 += count }
                }
                return sum.value
            }
            if total != options.expectedEntries {
                Findings.shared.violation(
                    "parallel listings of all folders do not add up",
                    "\(total) instead of \(options.expectedEntries)"
                )
            }
        }
    }

    /// What the shell asks on the main thread for an open archive.
    @MainActor
    internal func askOnMain() {
        step("harness loop on main: item(at:)+capabilities x20k") {
            var random = Random(seed: options.seed)
            var missing = 0
            for _ in 0..<20_000 {
                let index = Int.random(in: 0..<options.expectedEntries, using: &random)
                if bench.zip.item(at: bench.inside(archive, memberPath(index))) == nil {
                    missing += 1
                }
                _ = bench.zip.capabilities(for: root)
            }
            if missing > 0 {
                Findings.shared.violation("item(at:) did not find a member", "\(missing) of 20000")
            }
        }
    }

    /// Reads every probe once and compares it with the reference.
    @MainActor
    internal func readProbesOnce() {
        step("read all 64 probes once, verify") {
            offMain { [self] in
                for probe in probes {
                    let got = bench.readAll(bench.inside(archive, probe.path))
                    if got.data != probe.data {
                        Findings.shared.violation(
                            "probe read wrong before any change",
                            "\(probe.path): \(String(describing: got.error))"
                        )
                    }
                }
            }
        }
    }
}
