import FileOperationsPlugin
import Foundation
import StressKit

/// Preparing and checking the moves.
extension Layout {
    /// Makes some of the folders at the place the files go, so that their files are merged.
    ///
    /// Before a move half of the folders exist at the target already, so that their files are moved
    /// one by one (a merge); the others go with one rename each. Before a move back, a third of the
    /// folders exist at the source again: their files come back one by one.
    internal func prepareMove(seed: Int, back: Bool) {
        guard back else {
            try? FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
            for folder in 0..<folderCount where (folder + seed).isMultiple(of: 2) {
                try? FileManager.default.createDirectory(
                    at: moved.appendingPathComponent(String(format: "d%04d", folder)),
                    withIntermediateDirectories: true
                )
            }
            if seed.isMultiple(of: 2) {
                try? FileManager.default.createDirectory(
                    at: moved.appendingPathComponent("big"),
                    withIntermediateDirectories: true
                )
            }
            return
        }
        for folder in 0..<folderCount where (folder + seed).isMultiple(of: 3) {
            try? FileManager.default.createDirectory(
                at: source.appendingPathComponent(String(format: "d%04d", folder)),
                withIntermediateDirectories: true
            )
        }
    }

    /// After a move (`kind` "move" or "move-back"): no file is lost or damaged, and a run that was
    /// not cancelled left nothing where it came from.
    internal func verifyMove(seed: Int, kind: String, outcome: Outcome, back: Bool) {
        checkErrors("\(kind)#\(seed)", outcome)
        let atSource = Tree.survey(source, entries: manifest)
        let atMoved = Tree.survey(moved, entries: manifest)
        var tally = MoveTally()
        for index in manifest.indices {
            tally.count(index: index, atSource: atSource[index], atMoved: atMoved[index], back: back)
        }
        if tally.lost > 0 {
            Findings.shared.violation(
                "\(kind): FILE LOST (neither at source nor at target)",
                "seed \(seed) cancelled=\(outcome.result.cancelled): \(tally.lost) files, e.g. \(example(tally))"
            )
        }
        if tally.damaged > 0 {
            Findings.shared.violation(
                "\(kind): file damaged/partial under its name",
                "seed \(seed) cancelled=\(outcome.result.cancelled): \(tally.damaged), e.g. \(example(tally))"
            )
        }
        if tally.both > 0 {
            say("note: \(kind)#\(seed): \(tally.both) files exist at both ends (cancelled=\(outcome.result.cancelled))")
        }
        if !outcome.result.cancelled, tally.notMoved > 0 {
            Findings.shared.violation(
                "\(kind): finished without cancel but files remain at the source",
                "seed \(seed): \(tally.notMoved)"
            )
        }
        _ = checkNoTemporaries("\(kind)#\(seed)", [source, moved])
    }

    /// The path of the first lost or damaged file of `tally`; empty when there is none.
    private func example(_ tally: MoveTally) -> String {
        tally.example.map { manifest[$0].path } ?? ""
    }
}
