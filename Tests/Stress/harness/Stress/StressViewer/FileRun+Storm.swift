import Foundation
import StressKit

@testable import ViewerPlugin

/// The storm: the window dragged wider and narrower while the text is being indexed.
extension FileRun {
    /// Forty new widths while the text is indexed, then one last layout that has to match the first.
    ///
    /// Every new width drops the layout before; all the while threads read rows and search, and the
    /// user scrolls. The last layout is one that nobody stops.
    internal func storm() {
        step("storm: 40 relayouts during indexing + 6 readers + 2 searchers + user", limit: 1_200) {
            stormRounds()
            say(
                String(
                    format: "  footprint at the end of the storm %.0f MB, peak RSS %.0f MB",
                    footprintMB(),
                    peakRSSMB()
                )
            )
            lastLayoutAfterStorm()
        }
    }

    /// The 40 relayouts, each with its readers (and, every fourth, two searchers).
    private func stormRounds() {
        var hammers: [Hammer] = []
        var peakThreads = 0
        for round in 0..<40 {
            let columns = 30 + Int(random.next() % 200)
            let wraps = !random.next().isMultiple(of: 4)
            let document = show(
                TextLayoutOptions(columns: columns, wordWrap: wraps, tabWidth: 8),
                keeping: random.next().isMultiple(of: 2)
            )
            let hammer = Hammer(document, columns: columns, label: "during indexing")
            hammer.start(threads: 6, searchers: round.isMultiple(of: 4) ? 2 : 0, seed: seed + UInt64(round))
            hammers.append(hammer)
            let end = now() + Double(random.next() % 400) / 1_000
            pump(upTo: 5) {
                Harness.userAction(pager, &random, mayStop: true)
                return now() > end
            }
            peakThreads = max(peakThreads, threadCount())
            // The readers of the layout that is replaced go on for a while, as a view's would.
            if hammers.count > 2 {
                let old = hammers.removeFirst()
                if !old.stop() {
                    fail("\(name): hammer threads do not end", "in the storm, round \(round)")
                }
                if round == 39 || round == 20 {
                    old.report()
                }
            }
        }
        say("  threads at most during the storm: \(peakThreads)")
        for hammer in hammers where !hammer.stop() {
            fail("\(name): hammer threads do not end", "at the end of the storm")
        }
        hammers.last?.report()
    }

    /// One last layout that nobody stops (a layout stopped with Esc stays unfinished by design).
    private func lastLayoutAfterStorm() {
        let last = show(TextLayoutOptions(columns: fit, wordWrap: true, tabWidth: 8), keeping: true)
        let started = now()
        let done = pump(upTo: 900) { !pager.isIndexing }
        say(
            String(
                format: "  the last layout was %@ %.3fs after the storm; shown document is the last one: %@",
                done ? "indexed" : "NOT indexed",
                now() - started,
                String(describing: last === pager.document)
            )
        )
        let first = firstDocument
        if done, last.lineCount != first.lineCount || last.rowCount != first.rowCount {
            fail(
                "\(name): the same layout after the storm has other rows",
                "rows \(last.rowCount) vs \(first.rowCount), lines \(last.lineCount) vs \(first.lineCount)"
            )
        }
        if !done {
            fail("\(name): the last layout of the storm is not indexed", "")
        }
    }
}
