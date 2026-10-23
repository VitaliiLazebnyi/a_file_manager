import AFMKernel
import Foundation

/// Finding: the next row whose text contains what the user typed.
extension CompareSession {
    /// The search behind `find`; nil when nothing is found or `cancellation` was set.
    nonisolated internal static func search(
        _ content: CompareContent,
        _ needle: String,
        from row: Int,
        forward: Bool,
        cancellation: CancellationFlag?
    ) -> Int? {
        let count: Int
        let sides: (Int, CompareSide) -> String?
        switch content {
        case .empty:
            return nil

        case .text(let left, let right, let diff, _):
            count = diff.rows.count
            sides = { candidate, side in
                let (document, index) =
                    side == .left ? (left, diff.rows[candidate].left) : (right, diff.rows[candidate].right)
                return index.flatMap { found in
                    document.lines.indices.contains(found) ? document.lines[found].text : nil
                }
            }

        case .binary(let left, let right, let diff):
            count = diff.rowCount
            sides = { candidate, side in
                let text = diff.text(of: side == .left ? left : right, row: candidate)
                return text.isEmpty ? nil : text
            }
        }
        guard count > 0, !needle.isEmpty else {
            return nil
        }
        for step in 1...count {
            if step & 0x3FF == 0, cancellation?.isCancelled == true {
                return nil
            }
            let candidate = ((row + (forward ? step : -step)) % count + count) % count
            for side in [CompareSide.left, .right]
            where sides(candidate, side)?.range(of: needle, options: .caseInsensitive) != nil {
                return candidate
            }
        }
        return nil
    }

    /// The next row, in either file, whose text contains `needle`, ignoring case; the search
    /// goes round at the ends.
    ///
    /// Blocks: for callers that are not the window.
    internal func find(_ needle: String, from row: Int, forward: Bool) -> Int? {
        Self.search(content, needle, from: row, forward: forward, cancellation: nil)
    }

    /// The same away from the main thread, so that a large file does not freeze the window; a
    /// newer search (or `cancel`) makes the older one stop and drops its answer.
    internal func find(
        _ needle: String,
        from row: Int,
        forward: Bool,
        completion: @escaping @MainActor (Int?) -> Void
    ) {
        findGeneration += 1
        let generation = findGeneration
        let cancellation = CancellationFlag()
        searching?.cancel()
        searching = cancellation
        if runsInline {
            completion(Self.search(content, needle, from: row, forward: forward, cancellation: nil))
            return
        }
        let compared = content
        CompareWorker.run("Compare find") { [weak self] in
            let found = Self.search(compared, needle, from: row, forward: forward, cancellation: cancellation)
            DispatchQueue.main.async { [weak self] in
                // Stale when another search started, or the texts changed, meanwhile.
                guard let self, !cancellation.isCancelled, findGeneration == generation else {
                    return
                }
                searching = nil
                completion(found)
            }
        }
    }
}
