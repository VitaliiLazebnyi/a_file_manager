import AFMContracts
import AFMKernel
import AppKit
import StressKit
import TestSupport

@testable import AFMShell

/// Scenario 2: a provider that stops answering; 100 refreshes of the dead share.
@MainActor
internal final class StalledScenario {
    /// The work directory.
    internal let work: URL
    /// A small local folder to start in and to leave to.
    internal let small: URL
    /// The provider that stops answering.
    internal let stall: StallFS
    /// The share on the provider.
    internal let share: URL
    /// The running program.
    internal let app: Running
    /// The panel that shows the share.
    internal let left: PanelViewController
    /// The program's main menu.
    internal let menu: NSMenu
    /// Threads after start-up, when idle.
    internal let baseline: Int

    /// Starts the program: `arguments[2]` is the work directory.
    internal init(arguments: [String]) {
        work = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let smallFolder = work.appendingPathComponent("small")
        small = smallFolder
        makeSmall(smallFolder, files: 40)
        let provider = StallFS()
        for folder in 0..<40 {
            for file in 0..<20 {
                provider.inner.addFile("/share/folder\(folder)/file\(file).txt", "content \(file)")
            }
        }
        for file in 0..<400 {
            provider.inner.addFile("/share/doc\(file).txt", "doc")
        }
        provider.inner.addFile("/other/place/a.txt")
        stall = provider
        share = provider.inner.url("/share")
        app = step("start-up") { () -> Running in
            let started = Running(left: smallFolder, right: smallFolder, home: smallFolder, providers: [provider])
            check(started.settle(), "start-up did not settle")
            // The window counts as the active one, so reading ahead is allowed as in real use.
            started.shell.panelCoordinator.isWindowActive = { true }
            return started
        }
        left = app.left
        menu = app.shell.makeMainMenu()
        step("idle baseline (1 s)") { pump(for: 1) }
        baseline = threadCount()
    }

    /// Runs the script and ends the process.
    internal func run() -> Never {
        step("A open the share while it still answers") {
            var done = false
            left.show(share, focus: nil, history: .record) { _ in done = true }
            check(pump(upTo: 20) { done && !left.isLoading }, "A: the share did not open")
            say("   rows=\(left.model.items.count) volume local=\(String(describing: left.model.volume?.isLocal))")
        }
        note("open")

        stall.isStalled = true
        say("---- the provider stops answering ----")
        actInTheShare()
        actAround()
        let threadsWhileStalled = leave()
        reportMainThreadCalls()
        refreshStorm()

        step("D release the stall; threads end") {
            stall.release()
            pump(for: 0.5)
        }
        let after = waitForThreads(atMost: baseline + 2, upTo: 8)
        say(
            "   blocked now=\(stall.blockedNow), most blocked at once=\(stall.mostBlockedAtOnce); "
                + "threads baseline=\(baseline) while stalled (after leaving)=\(threadsWhileStalled) "
                + "after release=\(after)"
        )
        check(stall.blockedNow == 0, "2: \(stall.blockedNow) provider calls still blocked after release")
        finish("scenario 2: stalled provider", baseline: baseline, app: app)
    }

    /// Prints the threads and the calls blocked in the provider after `what`.
    internal func note(_ what: String) {
        say(
            "   after \(what): threads=\(threadCount()) blocked in provider=\(stall.blockedNow) "
                + "[\(stall.blockedByMethod)]"
        )
    }

    /// One step of the user's while the provider is silent, then `seconds` of the run loop.
    internal func act(_ name: String, wait seconds: Double, _ body: () -> Void) {
        step("B " + name, limit: 30) {
            body()
            pump(for: seconds)
        }
        note(name)
    }

    /// `act` with 0.4 s of the run loop after it.
    internal func act(_ name: String, _ body: () -> Void) {
        act(name, wait: 0.4, body)
    }

    /// C: waits 3 s after leaving the share and says who is still blocked; returns the threads then.
    internal func leave() -> Int {
        let stillBlocked = step("C wait 3 s after leaving; who is still blocked") { () -> Int in
            pump(for: 3)
            return stall.blockedNow
        }
        note("3 s after leaving the share")
        let threadsWhileStalled = threadCount()
        say(
            "   blocked provider calls that did not end although the panel left: \(stillBlocked); "
                + "threads now \(threadsWhileStalled) (baseline \(baseline))"
        )
        return threadsWhileStalled
    }

    /// Prints every provider call, and the stacks of those that reached the main thread while stalled.
    internal func reportMainThreadCalls() {
        let (calls, main) = stall.snapshotCalls()
        say(
            "\nPROVIDER CALLS (all threads): "
                + calls.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        )
        say(
            "PROVIDER CALLS MADE ON THE MAIN THREAD WHILE THE PROVIDER WAS NOT ANSWERING "
                + "(each would freeze the window for as long as the server is silent): "
                + (main.isEmpty ? "none" : "")
        )
        for (method, entry) in main.sorted(by: { $0.key < $1.key }) {
            say("  * \(method) x\(entry.count); first stack:")
            for line in entry.stack.dropFirst(2).prefix(22) {
                say("      " + line)
            }
        }
        check(
            main.isEmpty,
            "2: \(main.count) kinds of provider calls reached the main thread while the provider stalled: "
                + main.keys.sorted().joined(separator: ", ")
        )
    }

    /// E: a user who keeps pressing Refresh on the dead share; does the rest of the program still work?
    internal func refreshStorm() {
        let other = work.appendingPathComponent("other")
        makeSmall(other, files: 300)
        step("E 100 x refresh of the dead share (50 ms apart)", limit: 60) {
            left.show(share, focus: nil, history: .record, completion: nil)
            pump(for: 0.3)
            for _ in 0..<100 {
                app.commands.perform(.reread)
                pump(for: 0.05)
            }
        }
        note("100 refreshes of the dead share")
        var localLoad: Double?
        step("E2 open a LOCAL folder in the other panel meanwhile", limit: 60) {
            var done = false
            let started = now()
            app.right.show(other, focus: nil, history: .record) { _ in done = true }
            if pump(upTo: 20, until: { done && !app.right.isLoading }) {
                localLoad = now() - started
            }
        }
        if let localLoad {
            let format = "   local folder (300 files) opened in %.3f s while %d provider calls are blocked"
            say(String(format: format, localLoad, stall.blockedNow))
        } else {
            say(
                "   LOCAL FOLDER DID NOT OPEN WITHIN 20 s while \(stall.blockedNow) provider calls are blocked "
                    + "(threads=\(threadCount()))"
            )
        }
        let took = localLoad.map { String(format: "%.1f s", $0) } ?? "more than 20 s"
        check(
            (localLoad ?? .infinity) < 2,
            "2/E: with \(stall.blockedNow) calls blocked in a dead provider, a local folder took \(took) to open"
        )
        note("local load")
    }

    deinit {
        // Nothing to release.
    }
}
