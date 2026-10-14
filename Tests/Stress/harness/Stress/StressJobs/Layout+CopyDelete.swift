import FileOperationsPlugin
import Foundation

/// Checking the copies and deletes.
extension Layout {
    /// After a copy: the source is untouched, no partial file stands under its final name, a run
    /// that was not cancelled copied everything, and nothing else arrived.
    internal func verifyCopy(seed: Int, outcome: Outcome, sources: [URL]) {
        checkErrors("copy#\(seed)", outcome)
        let (src, dst) = (Tree.survey(source, entries: manifest), Tree.survey(destination, entries: manifest))
        var lost = 0
        var damaged = 0
        var partial = 0
        var missingAfterFullRun = 0
        for index in manifest.indices {
            lost += src[index] == 0 ? 1 : 0
            damaged += src[index] == 2 ? 1 : 0
            partial += dst[index] == 2 ? 1 : 0
            missingAfterFullRun += dst[index] == 0 && !outcome.result.cancelled ? 1 : 0
        }
        if lost > 0 {
            Findings.shared.violation("copy: source file gone", "seed \(seed): \(lost) files")
        }
        if damaged > 0 {
            Findings.shared.violation("copy: source file changed", "seed \(seed): \(damaged) files")
        }
        if partial > 0 {
            let example = manifest.indices.first { dst[$0] == 2 }.map { manifest[$0].path } ?? ""
            Findings.shared.violation(
                "copy: partial/different file under its final name",
                "seed \(seed) cancelled=\(outcome.result.cancelled): \(partial) files, e.g. \(example)"
            )
        }
        if missingAfterFullRun > 0 {
            Findings.shared.violation(
                "copy: finished without cancel but files missing at target",
                "seed \(seed): \(missingAfterFullRun)"
            )
        }
        verifyCopyTarget(seed: seed, outcome: outcome, sources: sources)
    }

    /// After a copy: no temporary files, nothing unexpected at the target, every source reported.
    private func verifyCopyTarget(seed: Int, outcome: Outcome, sources: [URL]) {
        let trees = checkNoTemporaries("copy#\(seed)", [source, destination])
        let extra = (trees["dst"]?.files ?? []).filter { !manifestPaths.contains($0) && !Tree.isTemporary($0) }
        if let first = extra.first {
            Findings.shared.violation(
                "copy: unexpected file at target",
                "seed \(seed): \(extra.count), e.g. \(first)"
            )
        }
        if !outcome.result.cancelled, outcome.result.completed.count != sources.count {
            Findings.shared.violation(
                "copy: not every source reported completed",
                "seed \(seed): \(outcome.result.completed.count)/\(sources.count)"
            )
        }
    }

    /// After a delete: nothing outside the deleted folders was touched, nothing was left damaged,
    /// and a run that was not cancelled removed everything.
    internal func verifyDelete(seed: Int, outcome: Outcome, before: [UInt8]) {
        checkErrors("delete#\(seed)", outcome)
        let (src, dst) = (Tree.survey(source, entries: manifest), Tree.survey(destination, entries: manifest))
        let lost = src.filter { $0 != 1 }.count
        if lost > 0 {
            Findings.shared.violation(
                "delete: a file outside the deleted folder was touched",
                "seed \(seed): \(lost)"
            )
        }
        var damaged = 0
        var left = 0
        for index in manifest.indices {
            damaged += dst[index] == 2 || (dst[index] == 1 && before[index] != 1) ? 1 : 0
            left += dst[index] != 0 ? 1 : 0
        }
        if damaged > 0 {
            Findings.shared.violation("delete: file left damaged", "seed \(seed): \(damaged)")
        }
        if !outcome.result.cancelled, left > 0 {
            Findings.shared.violation("delete: finished without cancel but files remain", "seed \(seed): \(left)")
        }
        if !outcome.result.cancelled, !Tree.topLevel(destination).isEmpty {
            Findings.shared.violation(
                "delete: finished without cancel but folders remain",
                "seed \(seed): \(Tree.topLevel(destination).count)"
            )
        }
        _ = checkNoTemporaries("delete#\(seed)", [destination])
    }
}
