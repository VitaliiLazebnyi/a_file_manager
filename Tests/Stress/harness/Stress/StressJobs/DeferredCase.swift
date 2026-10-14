import AFMKernel
import Foundation
import TestSupport

/// One run against the deferring target, as its check needs it: a source file may only be
/// removed once a successful commit covers its write at the target.
internal struct DeferredCase: Sendable {
    /// The seed of the run.
    internal let seed: Int
    /// The local tree that was moved.
    internal let source: URL
    /// Its files.
    internal let entries: [Entry]
    /// The target's files.
    internal let memory: MemoryFileSystem
    /// The target, with what it noted.
    internal let target: DeferredTarget
    /// The commits the target saw.
    internal let counts: CommitCounts
    /// How many commits in a hundred failed.
    internal let failureRate: Int
    /// The job's batch size.
    internal let batch: Int
    /// Whether the job was cancelled.
    internal let cancelled: Bool

    /// Checks every file, then makes the source whole again for the next seed.
    internal func verify() -> DeferredTally {
        let state = Tree.survey(source, entries: entries)
        var tally = DeferredTally()
        for (index, entry) in entries.enumerated() {
            if state[index] == 2 {
                Findings.shared.violation("deferred: source damaged", "seed \(seed): \(entry.path)")
            }
            if state[index] == 0 {
                tally.removed += 1
                checkRemoved(entry)
            } else {
                tally.kept += 1
            }
        }
        checkTotals(tally)
        // The next seed starts from the whole tree again.
        let missing = entries.indices.filter { state[$0] != 1 }.map { entries[$0] }
        Tree.build(at: source, entries: missing)
        return tally
    }

    /// A removed source file: it arrived whole, and a successful commit covers its write.
    private func checkRemoved(_ entry: Entry) {
        let path = "/out/" + entry.path
        guard let arrived = contents(path) else {
            Findings.shared.violation(
                "deferred: FILE LOST (source removed, nothing at target)",
                "seed \(seed) rate=\(failureRate) batch=\(batch): \(entry.path)"
            )
            return
        }
        if arrived != entry.content() {
            Findings.shared.violation(
                "deferred: source removed, target content differs",
                "seed \(seed): \(entry.path)"
            )
        } else if let writtenAt = target.writtenAt(path), writtenAt > counts.covered {
            Findings.shared.violation(
                "deferred: SOURCE REMOVED WITHOUT A SUCCESSFUL COMMIT covering its write",
                "seed \(seed) rate=\(failureRate)% batch=\(batch) commits ok/failed=\(counts.succeeded)/"
                    + "\(counts.failed): \(entry.path) written at \(writtenAt), last good commit covers "
                    + "\(counts.covered)"
            )
        } else if target.writtenAt(path) == nil {
            Findings.shared.violation(
                "deferred: source removed, target write not seen by the harness",
                "seed \(seed): \(entry.path)"
            )
        }
    }

    /// The whole run: nothing removed without a commit, everything removed when all succeeded, no
    /// temporary file at either end.
    private func checkTotals(_ tally: DeferredTally) {
        if counts.succeeded == 0, tally.removed > 0 {
            Findings.shared.violation(
                "deferred: sources removed although no commit succeeded",
                "seed \(seed): \(tally.removed)"
            )
        }
        if !cancelled, counts.failed == 0, tally.kept > 0 {
            Findings.shared.violation(
                "deferred: finished, every commit succeeded, but sources remain",
                "seed \(seed): \(tally.kept)"
            )
        }
        for path in memory.allPaths where Tree.isTemporary(path) {
            Findings.shared.violation("deferred: temporary file left at target", "seed \(seed): \(path)")
        }
        for path in Tree.walk(source).files where Tree.isTemporary(path) {
            Findings.shared.violation("deferred: temporary file left at source", "seed \(seed): \(path)")
        }
    }

    /// What the target holds at `path`; nil when there is no such file.
    private func contents(_ path: String) -> Data? {
        guard let reader = try? memory.read(memory.url(path)) else {
            return nil
        }
        var all = Data()
        while let block = try? reader.read(upToCount: 1 << 20) {
            all.append(block)
        }
        reader.close()
        return all
    }
}
