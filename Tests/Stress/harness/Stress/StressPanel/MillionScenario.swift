import AFMContracts
import AFMKernel
import AppKit
import StressKit

@testable import AFMShell

/// Scenario 1: a directory of a million files in a panel, the whole script.
@MainActor
internal final class MillionScenario {
    /// The directory with the million files.
    internal let big: URL
    /// A small folder to start in and to leave to.
    internal let small: URL
    /// The running program.
    internal let app: Running
    /// The panel that shows the big directory.
    internal let left: PanelViewController
    /// The program's main menu.
    internal let menu: NSMenu
    /// Threads after start-up, when idle.
    internal let baseline: Int
    /// Rows of the big directory once loaded.
    internal var total = 0
    /// Files the generator made in the big directory (1,000,000 unless a fourth argument says otherwise).
    internal let expected: Int

    /// Starts the program: `arguments[2]` is the big directory, `arguments[3]` the work directory, and
    /// `arguments[4]`, when given, how many files the generator made (for a smaller smoke run).
    internal init(arguments: [String]) {
        expected = arguments.count > 4 ? Int(arguments[4]) ?? 1_000_000 : 1_000_000
        big = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let work = URL(fileURLWithPath: arguments[3], isDirectory: true)
        let smallFolder = work.appendingPathComponent("small")
        small = smallFolder
        makeSmall(smallFolder, files: 40)
        app = step("start-up (kernel, 21 plugins, shell)") { () -> Running in
            let started = Running(left: smallFolder, right: smallFolder, home: smallFolder, providers: [])
            check(started.settle(), "start-up did not settle")
            return started
        }
        left = app.left
        menu = app.shell.makeMainMenu()
        step("idle baseline (1 s)") { pump(for: 1) }
        baseline = threadCount()
    }

    /// Runs the script and ends the process.
    internal func run() -> Never {
        load()
        sortAll()
        quickFilter()
        cursorBeforeMarking()
        marking()
        cursorWithMarks()
        validation()
        leaveAndComeBack()
        churnReloads()
        finalReload()
        finish("scenario 1: 1,000,000 files in a panel", baseline: baseline, app: app)
    }

    /// 1: loads the big directory, lays it out and draws it.
    internal func load() {
        var firstRows: Double?
        var done = false
        let started = now()
        step("1a load 1M-file directory", limit: 300) {
            left.show(big, focus: nil, history: .record) { _ in done = true }
            let ended = pump(upTo: 280) {
                if firstRows == nil, left.model.directory.path == big.path, !left.model.items.isEmpty {
                    let seconds = now() - started
                    firstRows = seconds
                    say(String(format: "   first rows after %.3f s: %d rows", seconds, left.model.items.count))
                }
                return done && !left.isLoading
            }
            check(ended, "1a: loading the directory did not end in 280 s")
        }
        total = left.model.items.count
        say(
            String(
                format: "   LOAD: first rows %.3f s, complete %.3f s, rows=%d isComplete=%@",
                firstRows ?? -1,
                now() - started,
                total,
                "\(left.model.isComplete)"
            )
        )
        check(total >= expected, "1a: only \(total) rows listed")
        step("1b layout + draw table (1M rows)") {
            app.layOut()
            app.draw(left)
        }
        step("1c idle 1 s after load") { pump(for: 1) }
    }

    /// 2: sorts through the ViewOptions commands.
    internal func sortAll() {
        sort("by extension", .sortByExtension)
        sort("by size", .sortBySize)
        sort("by time", .sortByTime)
        sort("reversed", .reversedOrder)
        sort("by name", .sortByName)
        sort("reversed (name desc)", .reversedOrder)
        sort("reversed (name asc)", .reversedOrder)
        step("2x draw after sorts") { app.draw(left) }
    }

    /// One sort command, waited for until the order changes.
    internal func sort(_ name: String, _ command: CommandID) {
        let before = left.model.sort
        step("2 sort: \(name)", limit: 200) {
            app.commands.perform(command)
            let arrived = pump(upTo: 180) { left.model.sort != before }
            check(arrived, "2: sort \(name) did not arrive in 180 s")
            pump(for: 0.2)
        }
        let order = left.model.sort
        let first = left.model.items.first?.name ?? "-"
        say("   order now key=\(order.key) descending=\(order.descending) first=\(first)")
    }

    deinit {
        // Nothing to release.
    }
}
