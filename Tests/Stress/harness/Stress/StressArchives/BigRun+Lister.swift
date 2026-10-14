import AFMKernel
import Foundation
import StressKit

/// The lister thread of the concurrent stage.
extension BigRun {
    /// Lists the root, a random folder and the added members, and asks for a member, until `stop`.
    internal func listerLoop(stop: CancellationFlag) {
        var random = Random(seed: options.seed &* 77)
        var lastAdded = 0
        while !stop.isCancelled {
            do {
                try listRound(random: &random, lastAdded: &lastAdded)
                Counter.shared.add("listing rounds")
            } catch {
                Findings.shared.violation("listing failed", "\(error.localizedDescription)")
            }
        }
    }

    /// One round of the lister; `lastAdded` is how many batches the added folder had last time.
    private func listRound(random: inout Random, lastAdded: inout Int) throws {
        let started = now()
        let top = try bench.zip.list(root, showHidden: true, cancellation: CancellationFlag())
        if top.count < folders + 1 || top.count > folders + 2 {
            Findings.shared.violation("root listing wrong during the changes", "\(top.count) items")
        }
        Counter.shared.time("list root", now() - started)
        let folder = Int.random(in: 0..<folders, using: &random)
        let folderStarted = now()
        let items = try bench.zip.list(folderURL(folder), showHidden: true, cancellation: CancellationFlag())
        Counter.shared.time("list folder of 500", now() - folderStarted)
        if items.count != 500 {
            Findings.shared.violation("folder listing wrong during the changes", "dir\(folder): \(items.count)")
        }
        if top.contains(where: { $0.name == "added" }) {
            let batches = try bench.zip.list(bench.inside(archive, "added"), showHidden: true)
            if batches.count < lastAdded {
                Findings.shared.violation("the added folder shrank", "\(lastAdded) -> \(batches.count)")
            }
            lastAdded = batches.count
        }
        let index = Int.random(in: 0..<options.expectedEntries, using: &random)
        if bench.zip.item(at: bench.inside(archive, memberPath(index))) == nil {
            Findings.shared.violation("item(at:) lost a member during the changes", "f\(index)")
        }
    }
}
