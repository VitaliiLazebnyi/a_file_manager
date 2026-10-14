import AFMContracts
import AFMKernel
import AppKit
import StressKit
import TestSupport

@testable import AFMShell

/// Scenario 1, steps 3 to 5: the quick filter, the cursor and marking.
extension MillionScenario {
    /// How many rows the mask of 4 of the 12 extensions should mark: 300,000 to 340,000 of a million.
    internal var markRange: ClosedRange<Int> {
        (expected * 3 / 10)...(expected * 34 / 100)
    }

    /// True when no quick filter waits or runs.
    internal var isFilterSettled: Bool {
        left.pendingQuickFilter == nil && left.filterJobs.isEmpty
    }

    /// 3a to 3d: the quick filter, a key at a time, then fast, then removed.
    internal func quickFilter() {
        step("3a quick filter: open field") {
            left.showQuickFilter()
            pump(for: 0.2)
        }
        let typed = "item00012"
        for length in 1...typed.count {
            let text = String(typed.prefix(length))
            step("3b quick filter typed slowly '\(text)'", limit: 120) {
                left.quickFilterEdited(text)
                let settled = pump(upTo: 100) { isFilterSettled && left.quickFilterText == text }
                check(settled, "3b: filter '\(text)' did not settle")
            }
            say("   '\(text)' -> \(left.model.items.count) rows")
        }
        step("3c quick filter typed fast '.swift' (30 ms/key)", limit: 120) {
            for length in 0...6 {
                left.quickFilterEdited(String(".swift".prefix(length)))
                pump(for: 0.03)
            }
            check(pump(upTo: 100) { isFilterSettled }, "3c: fast typing did not settle")
        }
        say("   '.swift' -> \(left.model.items.count) rows")
        step("3d quick filter removed (Esc)", limit: 120) {
            left.removeQuickFilter()
            let whole = pump(upTo: 100) { isFilterSettled && left.model.items.count == total }
            check(whole, "3d: list did not come back whole")
        }
    }

    /// 3y, 3z: the cursor with nothing marked.
    internal func cursorBeforeMarking() {
        step("3y cursor: 300 x Page Down, nothing marked", limit: 120) {
            timed(300) { _ in app.commands.perform(.cursorPageDown) }
            pump(for: 0.15)
        }
        step("3z cursor: 300 x one row down, nothing marked", limit: 120) {
            timed(300) { _ in left.model.moveCursor(to: left.model.cursor + 1) }
            pump(for: 0.15)
        }
    }

    /// 4a to 4f: select all, invert, select by mask, invert twice, draw.
    internal func marking() {
        step("4a select all (\(total))", limit: 120) {
            app.commands.perform(.selectAll)
            let marked = pump(upTo: 100) { left.model.selectionCount >= total - 300 }
            check(marked, "4a: select all marked \(left.model.selectionCount)")
            pump(for: 0.15)
        }
        say("   marked=\(left.model.selectionCount)")
        step("4b invert selection", limit: 120) {
            app.commands.perform(.invertSelection)
            let inverted = pump(upTo: 100) { left.model.selectionCount == 0 }
            check(inverted, "4b: invert left \(left.model.selectionCount) marked")
            pump(for: 0.15)
        }
        say("   marked=\(left.model.selectionCount)")
        let byMask = selectByMask()
        invert("4d invert selection (to ~667k)", expecting: total - byMask)
        invert("4e invert selection (back to ~333k)", expecting: byMask)
        step("4f draw with 333k marked") { app.draw(left) }
    }

    /// 4c: marks by a mask of 4 of the 12 extensions; returns how many are marked.
    internal func selectByMask() -> Int {
        step("4c select group by mask (4 of 12 extensions)", limit: 120) {
            app.interaction.promptAnswers = [.text("*.txt;*.swift;*.jpg;*.png")]
            let asked = now()
            app.commands.perform(.selectGroup)
            // On a long list the Selection plugin works the mask out in the background and marks when it is done.
            let arrived = pump(upTo: 100) {
                markRange.contains(left.model.selectionCount) && !app.kernel.jobs.isBusy
            }
            let state = arrived ? "arrived" : "did NOT arrive"
            say(String(format: "   marks of the mask %@ after %.3f s", state, now() - asked))
            pump(for: 0.15)
        }
        let byMask = left.model.selectionCount
        say("   marked=\(byMask)")
        let about = grouped(expected / 3)
        check(
            byMask > markRange.lowerBound && byMask < markRange.upperBound,
            "4c: mask marked \(byMask), expected about \(about)"
        )
        return byMask
    }

    /// Inverts the selection and checks that `expected` rows are marked then.
    internal func invert(_ name: String, expecting expected: Int) {
        let label = String(name.prefix(2))
        step(name, limit: 120) {
            app.commands.perform(.invertSelection)
            let inverted = pump(upTo: 100) { left.model.selectionCount == expected }
            check(inverted, "\(label): invert left \(left.model.selectionCount) marked, expected \(expected)")
            pump(for: 0.15)
        }
        say("   marked=\(left.model.selectionCount)")
    }

    /// 5a to 5c: the cursor with about 333k marked.
    internal func cursorWithMarks() {
        step("5a cursor: 1000 x Page Down command", limit: 120) {
            timed(1_000) { _ in app.commands.perform(.cursorPageDown) }
            pump(for: 0.15)
        }
        step("5b cursor: 1000 x random row", limit: 120) {
            var random = Random(seed: 5)
            timed(1_000) { _ in left.model.moveCursor(to: Int.random(in: 0..<left.model.rowCount, using: &random)) }
            pump(for: 0.15)
        }
        step("5c cursor: 300 x select-and-move-down (Insert)", limit: 120) {
            timed(300) { _ in app.commands.perform(.toggleSelectionAndMoveDown) }
            pump(for: 0.15)
        }
    }
}

/// `number` with a comma between each group of three digits (333,333).
internal func grouped(_ number: Int) -> String {
    var text = String(number)
    var index = text.count - 3
    while index > 0 {
        text.insert(",", at: text.index(text.startIndex, offsetBy: index))
        index -= 3
    }
    return text
}
