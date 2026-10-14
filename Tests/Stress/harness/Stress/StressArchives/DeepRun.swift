import AFMKernel
import Foundation
import StressKit

@testable import ArchivesPlugin

/// The run of `--mode deep`: walks the deeply nested ZIP (`deep.zip`).
internal final class DeepRun: Sendable {
    /// `deep.zip`.
    internal let archive: URL
    /// The program's file systems.
    internal let bench: Bench
    /// The archive's root in the writable scheme.
    internal let root: URL
    /// How deep the chain of folders `c/c/…` goes.
    internal let chainDepth: Int

    /// The path of the chain's bottom folder.
    internal var bottomPath: String {
        Array(repeating: "c", count: chainDepth).joined(separator: "/")
    }

    /// Prepares the bench.
    internal init(options: Options) {
        archive = options.directory.appendingPathComponent("deep.zip")
        bench = Bench(flushDelay: 1)
        root = bench.inside(archive)
        chainDepth = options.chainDepth
    }

    /// Runs every step.
    @MainActor
    internal func run() {
        openAndList()
        walkChain()
        loadBottom()
        walkTree()
        walkLongPath()
        addAtBottom()
        step("deep: close the store") { bench.store.close() }
    }

    /// Opens the archive and lists its root the way a panel does.
    @MainActor
    private func openAndList() {
        step("deep: open + list root (panel path)", limit: 300) {
            let loaded = panelLoad(bench, root)
            say(
                String(
                    format: "LOAD deep root: first %.3fs complete %.3fs, %d items error=%@",
                    loaded.first,
                    loaded.total,
                    loaded.count,
                    "\(String(describing: loaded.error))"
                )
            )
            if loaded.count != 3 {
                Findings.shared.violation("deep root listing wrong", "\(loaded.count) items")
            }
        }
    }

    /// Walks down the chain, listing each level, and reads the leaf at its bottom.
    @MainActor
    private func walkChain() {
        step("deep: walk down the chain of \(chainDepth) folders (list each level)", limit: 600) {
            let reached: Int = offMain { [self] in descendChain() }
            if reached != chainDepth {
                Findings.shared.violation("deep chain not walked to the bottom", "level \(reached) of \(chainDepth)")
            }
        }
    }

    /// Goes down the chain as far as it reaches; returns the level.
    private func descendChain() -> Int {
        var url = root
        var level = 0
        var slowest = 0.0
        while true {
            let started = now()
            guard let items = try? bench.zip.list(url, showHidden: true),
                let next = items.first(where: { $0.isDirectory && $0.name == "c" })
            else {
                break
            }
            slowest = max(slowest, now() - started)
            url = next.url
            level += 1
        }
        say(String(format: "deep chain: reached level %d, slowest listing %.2f ms", level, slowest * 1_000))
        let leaf = bench.readAll(url.appending(name: "leaf.txt"))
        if leaf.data != Data("bottom of the chain\n".utf8) {
            Findings.shared.violation("deep leaf read wrong", "\(String(describing: leaf.error))")
        }
        return level
    }

    /// Loads the bottom of the chain the way a panel does, and asks what the path bar and the title ask.
    @MainActor
    private func loadBottom() {
        step("deep: panel load at the bottom of the chain", limit: 300) {
            let bottom = bench.inside(archive, bottomPath)
            let loaded = panelLoad(bench, bottom)
            say(
                String(
                    format: "LOAD deep bottom: first %.3fs complete %.3fs, %d items error=%@",
                    loaded.first,
                    loaded.total,
                    loaded.count,
                    "\(String(describing: loaded.error))"
                )
            )
            if loaded.count != 1 {
                Findings.shared.violation(
                    "deep bottom listing wrong",
                    "\(loaded.count) items, error \(String(describing: loaded.error))"
                )
            }
            // What the path bar and the title show, on the main thread.
            _ = bench.fileSystems.displayPath(bottom)
            _ = bench.zip.parent(of: bottom)
            _ = bench.zip.item(at: bottom)
        }
    }

    /// Walks the binary tree and reads every member.
    @MainActor
    private func walkTree() {
        step("deep: walk the binary tree (8191 folders) and read every node", limit: 600) {
            let nodes: Int = offMain { [self] in countMembers(below: bench.inside(archive, "t")) }
            if nodes != 8_191 {
                Findings.shared.violation("deep tree has the wrong number of members", "\(nodes)")
            }
        }
    }

    /// The members below `url`, each read once.
    private func countMembers(below url: URL) -> Int {
        guard let items = try? bench.zip.list(url, showHidden: true) else {
            return 0
        }
        var count = 0
        for item in items {
            if item.isDirectory {
                count += countMembers(below: item.url)
            } else {
                if bench.readAll(item.url).data == nil {
                    Findings.shared.violation("deep tree member unreadable", item.url.path)
                }
                count += 1
            }
        }
        return count
    }

    /// Walks to the member with a 60,000-byte path and reads it.
    @MainActor
    private func walkLongPath() {
        step("deep: the member with a 60,000-byte path", limit: 300) {
            offMain { [self] in
                var url = bench.inside(archive, "long")
                var levels = 0
                while let items = try? bench.zip.list(url, showHidden: true), let next = items.first {
                    if !next.isDirectory {
                        if bench.readAll(next.url).data != Data("long path\n".utf8) {
                            Findings.shared.violation("long-path member read wrong", "")
                        }
                        break
                    }
                    url = next.url
                    levels += 1
                }
                say("long path: \(levels) levels walked")
                if levels != 238 {
                    Findings.shared.violation("long path not walked to its end", "\(levels) of 238")
                }
            }
        }
    }

    deinit {
        // Nothing to release.
    }
}
