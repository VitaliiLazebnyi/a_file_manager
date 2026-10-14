internal import AppKit
internal import Foundation
internal import StressKit

@testable internal import FindFilesPlugin

/// Through the real window controller (prepare, startSearch, cancelSearch), never shown.
extension FindRun {
    /// Starts `test` the way the window's form would.
    internal func startThroughWindow(_ test: SearchCase) {
        window.prepare(startingIn: test.directory, includeHidden: false)
        var settings = window.form.settings
        settings.searchFor = test.names
        settings.findText = !test.text.isEmpty
        settings.text = test.text
        settings.useSpotlight = false
        window.form.settings = settings
        window.startSearch()
    }

    /// Every case once through the window, uncancelled; remembers how long each took.
    internal func windowRuns() {
        for test in cases {
            step("window: \(test.label)", limit: 900) {
                let before = finishedCount
                let started = now()
                startThroughWindow(test)
                var first = -1.0
                pump(upTo: 900) {
                    if first < 0, window.numberOfRows(in: NSTableView()) > 1 {
                        first = now() - started
                    }
                    return finishedCount > before
                }
                let seconds = now() - started
                typical[test.label] = seconds
                pump(for: 0.3)
                MainWatchdog.shared.setPhase("(harness: checking results)")
                let items = window.resultItems
                say(
                    String(
                        format: "  window %@: %d results in %.3fs, first rows after %.3fs, threads %d",
                        test.label,
                        items.count,
                        seconds,
                        first,
                        threadCount()
                    )
                )
                verify("window " + test.label, items, against: test.expected, filesOnly: true)
                pump(for: 0.3)
            }
        }
    }

    /// The thread count must come back to the baseline after the last search.
    internal func threadsSettle() {
        step("threads settle at the end") {
            var trace: [String] = []
            let started = now()
            for _ in 0..<60 {
                trace.append(String(format: "%.1fs:%d", now() - started, threadCount()))
                if threadCount() <= baselineThreads + 2 {
                    break
                }
                pump(for: 0.5)
            }
            say("threads over time after the last search: " + trace.joined(separator: " "))
            let end = threadCount()
            say("threads: baseline \(baselineThreads), at the end \(end)")
            if end > baselineThreads + 4 {
                fail("thread count did not return to the baseline: \(baselineThreads) -> \(end)")
            }
        }
    }

    /// After everything, an uncancelled search must still be complete.
    internal func windowRunsAfterTorture() {
        for test in cases.prefix(2) {
            step("window after torture: \(test.label)", limit: 900) {
                let before = finishedCount
                startThroughWindow(test)
                pump(upTo: 900) { finishedCount > before }
                pump(for: 0.3)
                verify("after torture " + test.label, window.resultItems, against: test.expected, filesOnly: true)
            }
        }
    }
}
