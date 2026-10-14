/// What the runs against the deferring target add up to.
internal struct DeferredTotals {
    /// Runs.
    internal var runs = 0
    /// Runs that were cancelled.
    internal var cancelled = 0
    /// Commits that succeeded.
    internal var commitsOK = 0
    /// Commits that failed.
    internal var commitsFailed = 0
    /// Source files that were removed.
    internal var removed = 0
    /// Source files that were kept.
    internal var kept = 0

    /// The `DEFERRED TOTAL` line.
    internal var line: String {
        "DEFERRED TOTAL runs=\(runs) cancelled=\(cancelled) commits ok=\(commitsOK) failed=\(commitsFailed) "
            + "sources removed=\(removed) kept=\(kept)"
    }

    /// Adds one run.
    internal mutating func add(cancelled wasCancelled: Bool, counts: CommitCounts, tally: DeferredTally) {
        runs += 1
        cancelled += wasCancelled ? 1 : 0
        commitsOK += counts.succeeded
        commitsFailed += counts.failed
        removed += tally.removed
        kept += tally.kept
    }
}
