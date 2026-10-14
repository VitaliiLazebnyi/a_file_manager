import AFMKernel
import Foundation
import StressKit

@testable import ViewerPlugin

/// The steps of a file's run, apart from the storm.
extension FileRun {
    /// The round trips of `roundTrips()`, on the calling thread.
    nonisolated private static func checkRoundTrips(_ document: TextDocument, name: String, seed: UInt64) {
        let count = document.rowCount
        var probe = Random(seed: seed + 5)
        for round in 0..<300 {
            let row: Int
            switch round {
            case 0:
                row = 0

            case 1:
                row = max(0, count - 1)

            default:
                row = Int(probe.next() % UInt64(max(1, count)))
            }
            checkRoundTrip(document, row: row, count: count, name: name)
        }
        if let last = try? document.rows(from: max(0, count - 1), count: 1).first,
            last.range.upperBound != document.content.upperBound
        {
            fail(
                "\(name): the last row does not end at the end of the file",
                "\(last.range) vs \(document.content.upperBound)"
            )
        }
    }

    /// From `row` to its offset and back, and to its line and back.
    nonisolated private static func checkRoundTrip(_ document: TextDocument, row: Int, count: Int, name: String) {
        guard let got = try? document.rows(from: row, count: 2), let first = got.first else {
            if count > 0 {
                fail("\(name): round trip: no row", "row \(row) of \(count)")
            }
            return
        }
        if let back = try? document.row(containing: first.range.lowerBound), back != row, !first.range.isEmpty {
            fail(
                "\(name): row(containing:) disagrees with rows(from:)",
                "row \(row) begins at \(first.range.lowerBound), which is said to be in row \(String(describing: back))"
            )
        }
        if let lineRow = try? document.row(ofLine: first.line) {
            if lineRow > row {
                fail(
                    "\(name): row(ofLine:) behind the row of that line",
                    "line \(first.line): row \(lineRow) > \(row)"
                )
            }
        } else {
            fail("\(name): row(ofLine:) finds no row", "line \(first.line) of row \(row)")
        }
    }

    /// Waits for the first layout's index to reach the end of the file.
    internal func indexToTheEnd() {
        step("index to the end (parallel)", limit: 1_000) {
            let started = now()
            let document = firstDocument
            let done = waitIndexed(document)
            say(
                String(
                    format: "  index %@ after %.3fs more: rows %d, lines %d, checkpoints %d, footprint %.0f MB, "
                        + "read error: %@",
                    done ? "complete" : "NOT complete",
                    now() - started,
                    document.rowCount,
                    document.lineCount,
                    document.checkpointCount,
                    footprintMB(),
                    String(describing: document.readError)
                )
            )
            if !done {
                fail("\(name): index not complete", "not within the limit")
            }
        }
    }

    /// Rows from 6 threads while the user is at the pager, 4 s, once the index is complete.
    internal func hammerIndexed() {
        step("indexed: rows from 6 threads + user at the pager, 4 s", limit: 300) {
            let hammer = Hammer(firstDocument, columns: fit, label: "indexed")
            hammer.start(threads: 6, searchers: 0, seed: seed)
            let end = now() + 4
            pump(upTo: 10) {
                Harness.userAction(pager, &random, mayStop: false)
                return now() > end
            }
            if !hammer.stop() {
                fail("\(name): hammer threads do not end", "after the index was complete")
            }
            hammer.report()
        }
    }

    /// The first and last rows, and 300 round trips between rows, offsets and lines, in the background.
    internal func roundTrips() {
        step("indexed: first/last rows and round trips", limit: 300) {
            let done = Shared(false)
            let document = firstDocument
            let name = name
            let seed = seed
            DispatchQueue.global(qos: .userInitiated)
                .async {
                    Self.checkRoundTrips(document, name: name, seed: seed)
                    DispatchQueue.main.async { done.value = true }
                }
            pump(upTo: 280) { done.value }
        }
    }

    /// Searches the whole file for the marker at its end.
    internal func searchMarker() {
        step("search forward: marker at the very end", limit: 700) {
            let (hit, seconds) = search(ViewerFiles.marker, from: 0, backwards: false, cancelAfter: nil)
            fullSearch = seconds
            let document = firstDocument
            say(
                String(
                    format: "  marker %@ in %.3fs (%.0f MiB/s)",
                    hit.map { "found at \($0.lowerBound)" } ?? "NOT found",
                    seconds,
                    Double(document.length) / 1_048_576 / seconds
                )
            )
            if name != "sparse4g.txt", name != "newlines1g.txt",
                hit?.upperBound != document.length - (name.hasPrefix("dense") ? 1 : 0)
            {
                fail("\(name): the marker at the end was not found where it is", "\(String(describing: hit))")
            }
        }
    }

    /// Searches backwards from the end for a text that is not there.
    internal func searchAbsent() {
        step("search backward from the end: absent text", limit: 700) {
            let (hit, seconds) = search(
                "zzz_not_there",
                from: firstDocument.length,
                backwards: true,
                cancelAfter: nil
            )
            say(String(format: "  absent text: %@ in %.3fs", hit == nil ? "not found" : "FOUND", seconds))
            if hit != nil {
                fail("\(name): found an absent text", "")
            }
        }
    }

    /// 30 searches cancelled at a random moment; the longest wait for one to return after its cancel.
    internal func searchCancelled() {
        step("search cancelled at random, 30 times", limit: 700) {
            var worst = 0.0
            for _ in 0..<30 {
                let after = Double(random.next() % 1_000) / 1_000 * min(fullSearch, 2)
                let (_, latency) = search("zzz_not_there", from: 0, backwards: false, cancelAfter: after)
                worst = max(worst, latency)
            }
            say(
                String(
                    format: "  cancel -> search returned: worst %.1f ms; threads now %d",
                    worst * 1_000,
                    threadCount()
                )
            )
        }
    }

    /// Lays the whole file out again in `options`, keeping the place, and times the index.
    internal func timedLayout(_ label: String, _ options: TextLayoutOptions) {
        step("relayout: \(label)", limit: 1_000) {
            let started = now()
            let document = show(options, keeping: true)
            let done = waitIndexed(document)
            let seconds = now() - started
            relayouts.append(Relayout(label: label, seconds: seconds, reused: document.segmentsReused))
            say(
                String(
                    format:
                        "  %@: %@ in %.3fs, segments reused %d, rows %d, lines %d, checkpoints %d, footprint %.0f MB",
                    label,
                    done ? "complete" : "NOT complete",
                    seconds,
                    document.segmentsReused,
                    document.rowCount,
                    document.lineCount,
                    document.checkpointCount,
                    footprintMB()
                )
            )
            if !done {
                fail("\(name): relayout not complete", label)
            }
            if document.lineCount != firstDocument.lineCount {
                fail(
                    "\(name): another layout counts other lines",
                    "\(label): \(document.lineCount) vs \(firstDocument.lineCount)"
                )
            }
        }
    }

    /// Closes the file; the threads have to go back to the baseline.
    internal func close() {
        step("close; threads settle", limit: 120) {
            pager.clear()
            source.close()
            var trace: [String] = []
            let started = now()
            for _ in 0..<40 {
                trace.append(String(format: "%.1fs:%d", now() - started, threadCount()))
                if threadCount() <= baselineThreads + 2 {
                    break
                }
                pump(for: 0.5)
            }
            say("  threads after closing: " + trace.joined(separator: " ") + " (baseline \(baselineThreads))")
            if threadCount() > baselineThreads + 4 {
                fail("\(name): threads do not return to the baseline", "\(baselineThreads) -> \(threadCount())")
            }
            say(String(format: "  footprint after closing %.0f MB, peak RSS %.0f MB", footprintMB(), peakRSSMB()))
        }
    }
}
