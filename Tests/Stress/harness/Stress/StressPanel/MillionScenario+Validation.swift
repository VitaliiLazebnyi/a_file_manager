import AFMKernel
import AppKit
import StressKit

@testable import AFMShell

/// Scenario 1, steps 6 and 7: validation with about 333k marked, leaving and coming back.
extension MillionScenario {
    /// 6a, 6, 6b: what validation costs with about 333k marked.
    internal func validation() {
        step("6a which commands' enabled/checked closures are slow") {
            reportSlowCommands()
            // What a real validation tick does (the bars), and what opening each top-level menu costs.
            let started = now()
            app.shell.mainWindow.validateBars()
            say(String(format: "   validateBars (the 0.1 s tick): %.2f ms", (now() - started) * 1_000))
            reportMenus()
        }
        step("6 validation x10 (bars, all commands, menu)", limit: 300) {
            validateTenTimes()
        }
        step("6b status line x50 with 333k marked") {
            for _ in 0..<50 {
                left.updateStatus()
                CFRunLoopRunInMode(.defaultMode, 0.002, true)
            }
        }
    }

    /// Prints what all commands' enabled and checked closures cost, and the slowest of them.
    internal func reportSlowCommands() {
        var costs: [(String, Double)] = []
        for command in app.kernel.commands.all {
            let started = now()
            _ = app.kernel.commands.isEnabled(command.id)
            _ = app.kernel.commands.isChecked(command.id)
            costs.append(("\(command.id) \"\(command.title)\"", (now() - started) * 1_000))
        }
        costs.sort { $0.1 > $1.1 }
        let sum = costs.reduce(0) { $0 + $1.1 }
        say(String(format: "   all %d commands: %.1f ms; the slowest:", costs.count, sum))
        for (name, cost) in costs.prefix(14) {
            say(String(format: "     %8.2f ms  %@", cost, name))
        }
    }

    /// Prints what validating each top-level menu with its submenus costs.
    internal func reportMenus() {
        for item in menu.items {
            guard let submenu = item.submenu else {
                continue
            }
            let started = now()
            app.validateItems(of: submenu)
            say(
                String(
                    format: "     menu '%@' (%d items incl. submenus): %.1f ms",
                    submenu.title,
                    submenu.items.count,
                    (now() - started) * 1_000
                )
            )
        }
    }

    /// Ten rounds of validation; prints the average round by part and the worst round.
    internal func validateTenTimes() {
        var sums = ValidationTimes(bars: 0, commands: 0, menu: 0)
        var worst = 0.0
        for _ in 0..<10 {
            let times = app.validateEverything(menu: menu)
            sums.bars += times.bars
            sums.commands += times.commands
            sums.menu += times.menu
            worst = max(worst, times.bars + times.commands + times.menu)
            CFRunLoopRunInMode(.defaultMode, 0.002, true)
        }
        let format =
            "   per round: bars %.2f ms, %d commands enabled+checked %.2f ms, menu items %.2f ms; worst round %.2f ms"
        say(
            String(
                format: format,
                sums.bars * 100,
                app.kernel.commands.all.count,
                sums.commands * 100,
                sums.menu * 100,
                worst * 1_000
            )
        )
    }

    /// 7a, 7b: leaves for a small folder and comes back; the remembered listing is shown, the fresh one
    /// merged behind.
    internal func leaveAndComeBack() {
        step("7a navigate away to a small folder", limit: 120) {
            var away = false
            left.show(small, focus: nil, history: .record) { _ in away = true }
            check(pump(upTo: 100) { away && !left.isLoading }, "7a: leaving did not end")
            pump(for: 0.3)
        }
        step("7b come back (remembered listing + fresh read)", limit: 300) {
            var back = false
            let started = now()
            var shown: Double?
            left.show(big, focus: nil, history: .record) { _ in back = true }
            let ended = pump(upTo: 280) {
                if shown == nil, left.model.directory.path == big.path, !left.model.items.isEmpty {
                    shown = now() - started
                }
                return back && !left.isLoading
            }
            check(ended, "7b: coming back did not end")
            say(
                String(
                    format: "   rows shown after %.3f s, fresh after %.3f s, rows=%d",
                    shown ?? -1,
                    now() - started,
                    left.model.items.count
                )
            )
        }
    }
}
