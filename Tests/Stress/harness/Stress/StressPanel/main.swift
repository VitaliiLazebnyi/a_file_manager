import AFMContracts
import AFMKernel
import AppKit
import Darwin
import StandardPlugins
import StressKit
import TestSupport

@testable import AFMShell

// Scenarios 1 (a million files in a panel), 2 (a provider that stops answering) and
// 8 (a flood of changes in a watched folder), driven through the real kernel, the standard
// plugins and the real shell, without showing a window.
//
//   StressPanel million <directory with the files> <work directory>
//   StressPanel stalled <work directory>
//   StressPanel flood <work directory> [files] [ops per second] [seconds]

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    say("usage: StressPanel million|stalled|flood ...")
    exit(2)
}
let mode = arguments[1]
HangGuard.shared.sampleDirectory =
    ProcessInfo.processInfo.environment["STRESS_RESULTS"] ?? FileManager.default.currentDirectoryPath

let fm = FileManager.default
var failures: [String] = []
func check(_ ok: Bool, _ what: String) {
    if !ok {
        failures.append(what)
        say("FAIL: " + what)
    }
}

/// The program without a visible window: kernel, all standard plugins, shell.
final class Running {
    let kernel: Kernel
    let shell: Shell
    let ui = ScriptedInteraction()
    var left: PanelViewController { shell.panelCoordinator.leftPanel }
    var right: PanelViewController { shell.panelCoordinator.rightPanel }
    var commands: CommandRegistry { kernel.commands }

    init(left: URL, right: URL, home: URL, providers: [FileSystemProvider] = []) {
        let settings = MemorySettings()
        func state(_ folder: URL) -> PanelTabs.State { PanelTabs.State(tabs: [.init(location: folder)], active: 0) }
        settings.set(state(left), forKey: "left.tabs")
        settings.set(state(right), forKey: "right.tabs")
        kernel = Kernel(productName: StandardPlugins.productName, settings: settings, interaction: ui)
        providers.forEach(kernel.fileSystems.register)
        kernel.load(StandardPlugins.make(pasteboard: .withUniqueName(), launchesApplications: false))
        shell = Shell(kernel: kernel, home: home)
        shell.mainWindow.window?.setContentSize(NSSize(width: 1_500, height: 900))
        layOut()
    }

    func layOut() {
        shell.mainWindow.window?.contentView?.layoutSubtreeIfNeeded()
    }

    var isSettled: Bool { !shell.panelCoordinator.isLoading && !kernel.jobs.isBusy }

    func settle(upTo seconds: Double = 120) -> Bool { pump(upTo: seconds) { self.isSettled } }

    /// Has the list draw itself into a bitmap, as it would on screen.
    func draw(_ panel: PanelViewController) {
        let view: NSView = panel.showsGrid ? panel.gridView : panel.tableView
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.visibleRect) else { return }
        view.cacheDisplay(in: view.visibleRect, to: bitmap)
    }

    /// What the validation tick and an opened menu ask: every bar, every command, every menu item.
    func validateEverything(menu: NSMenu) -> (bars: Double, commands: Double, menu: Double) {
        let t0 = now()
        shell.mainWindow.validateBars()
        let t1 = now()
        for command in kernel.commands.all {
            _ = kernel.commands.isEnabled(command.id)
            _ = kernel.commands.isChecked(command.id)
        }
        let t2 = now()
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                _ = shell.mainWindow.validateMenuItem(item)
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        walk(menu)
        return (t1 - t0, t2 - t1, now() - t2)
    }

    func stop() {
        shell.shutDown()
        kernel.shutdown()
    }
}

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
MainWatchdog.shared.start()

func makeSmall(_ directory: URL, files: Int = 40) {
    try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    for index in 0..<files {
        fm.createFile(atPath: directory.appendingPathComponent("small\(index).txt").path, contents: Data("x".utf8))
    }
    try? fm.createDirectory(at: directory.appendingPathComponent("sub"), withIntermediateDirectories: true)
}

func finish(_ title: String, baseline: Int, app: Running) -> Never {
    step("shut down") {
        app.stop()
        pump(for: 0.5)
    }
    let after = step("threads return to baseline (up to 8 s)") {
        waitForThreads(atMost: baseline + 2, upTo: 8, onMain: true)
    }
    say("threads: baseline(after start-up)=\(baseline) after shut-down=\(after)")
    MainWatchdog.shared.report(title: title)
    say("\nFAILURES: \(failures.count)")
    failures.forEach { say("  - " + $0) }
    say(String(format: "peakRSS=%.0fMB footprint=%.0fMB", peakRSSMB(), footprintMB()))
    exit(failures.isEmpty ? 0 : 1)
}

/// Runs `body` `count` times with a turn of the run loop after each; reports how long single calls took.
func timed(_ count: Int, _ body: (Int) -> Void) {
    var durations: [Double] = []
    durations.reserveCapacity(count)
    for index in 0..<count {
        let t0 = now()
        body(index)
        durations.append((now() - t0) * 1_000)
        CFRunLoopRunInMode(.defaultMode, 0.0005, false)
    }
    durations.sort()
    say(
        String(
            format: "   single call: median %.2f ms, p99 %.2f ms, max %.2f ms, over 8 ms: %d of %d",
            durations[count / 2],
            durations[count * 99 / 100],
            durations[count - 1],
            durations.filter { $0 > 8 }.count,
            count
        )
    )
}

// MARK: - Scenario 1: a million files

func million() {
    let big = URL(fileURLWithPath: arguments[2], isDirectory: true)
    let work = URL(fileURLWithPath: arguments[3], isDirectory: true)
    let small = work.appendingPathComponent("small")
    makeSmall(small)
    let app = step("start-up (kernel, 21 plugins, shell)") { () -> Running in
        let app = Running(left: small, right: small, home: small)
        check(app.settle(), "start-up did not settle")
        return app
    }
    let left = app.left
    let menu = app.shell.makeMainMenu()
    step("idle baseline (1 s)") { pump(for: 1) }
    let baseline = threadCount()

    // Load.
    var firstRows: Double?
    var done = false
    let started = now()
    step("1a load 1M-file directory", limit: 300) {
        left.show(big, focus: nil, history: .record) { _ in done = true }
        let ok = pump(upTo: 280) {
            if firstRows == nil, left.model.directory.path == big.path, !left.model.items.isEmpty {
                firstRows = now() - started
                say(String(format: "   first rows after %.3f s: %d rows", firstRows!, left.model.items.count))
            }
            return done && !left.isLoading
        }
        check(ok, "1a: loading the directory did not end in 280 s")
    }
    let total = left.model.items.count
    say(
        String(
            format: "   LOAD: first rows %.3f s, complete %.3f s, rows=%d isComplete=%@",
            firstRows ?? -1,
            now() - started,
            total,
            "\(left.model.isComplete)"
        )
    )
    check(total >= 1_000_000, "1a: only \(total) rows listed")
    step("1b layout + draw table (1M rows)") {
        app.layOut()
        app.draw(left)
    }
    step("1c idle 1 s after load") { pump(for: 1) }

    // Sort through the ViewOptions commands.
    func sort(_ name: String, _ id: CommandID) {
        let before = left.model.sort
        step("2 sort: \(name)", limit: 200) {
            app.commands.perform(id)
            let ok = pump(upTo: 180) { left.model.sort != before }
            check(ok, "2: sort \(name) did not arrive in 180 s")
            pump(for: 0.2)
        }
        say(
            "   order now key=\(left.model.sort.key) descending=\(left.model.sort.descending) first=\(left.model.items.first?.name ?? "-")"
        )
    }
    sort("by extension", .sortByExtension)
    sort("by size", .sortBySize)
    sort("by time", .sortByTime)
    sort("reversed", .reversedOrder)
    sort("by name", .sortByName)
    sort("reversed (name desc)", .reversedOrder)
    sort("reversed (name asc)", .reversedOrder)
    step("2x draw after sorts") { app.draw(left) }

    // Quick filter, a key at a time.
    func filterSettled() -> Bool { left.pendingQuickFilter == nil && left.filterJobs.isEmpty }
    step("3a quick filter: open field") {
        left.showQuickFilter()
        pump(for: 0.2)
    }
    let typed = "item00012"
    for length in 1...typed.count {
        let text = String(typed.prefix(length))
        step("3b quick filter typed slowly '\(text)'", limit: 120) {
            left.quickFilterEdited(text)
            let ok = pump(upTo: 100) { filterSettled() && left.quickFilterText == text }
            check(ok, "3b: filter '\(text)' did not settle")
        }
        say("   '\(text)' -> \(left.model.items.count) rows")
    }
    step("3c quick filter typed fast '.swift' (30 ms/key)", limit: 120) {
        for length in 0...6 {
            left.quickFilterEdited(String(".swift".prefix(length)))
            pump(for: 0.03)
        }
        check(pump(upTo: 100) { filterSettled() }, "3c: fast typing did not settle")
    }
    say("   '.swift' -> \(left.model.items.count) rows")
    step("3d quick filter removed (Esc)", limit: 120) {
        left.removeQuickFilter()
        check(
            pump(upTo: 100) { filterSettled() && left.model.items.count == total },
            "3d: list did not come back whole"
        )
    }

    step("3y cursor: 300 x Page Down, nothing marked", limit: 120) {
        timed(300) { _ in app.commands.perform(.cursorPageDown) }
        pump(for: 0.15)
    }
    step("3z cursor: 300 x one row down, nothing marked", limit: 120) {
        timed(300) { _ in left.model.moveCursor(to: left.model.cursor + 1) }
        pump(for: 0.15)
    }
    // Marking.
    step("4a select all (\(total))", limit: 120) {
        app.commands.perform(.selectAll)
        check(
            pump(upTo: 100) { left.model.selectionCount >= total - 300 },
            "4a: select all marked \(left.model.selectionCount)"
        )
        pump(for: 0.15)
    }
    say("   marked=\(left.model.selectionCount)")
    step("4b invert selection", limit: 120) {
        app.commands.perform(.invertSelection)
        check(
            pump(upTo: 100) { left.model.selectionCount == 0 },
            "4b: invert left \(left.model.selectionCount) marked"
        )
        pump(for: 0.15)
    }
    say("   marked=\(left.model.selectionCount)")
    step("4c select group by mask (4 of 12 extensions)", limit: 120) {
        app.ui.promptAnswers = [.text("*.txt;*.swift;*.jpg;*.png")]
        let asked = now()
        app.commands.perform(.selectGroup)
        // On a long list the Selection plugin works the mask out in the background and marks when it is done.
        let arrived = pump(upTo: 100) {
            (300_000...340_000).contains(left.model.selectionCount) && !app.kernel.jobs.isBusy
        }
        say(
            String(
                format: "   marks of the mask %@ after %.3f s",
                arrived ? "arrived" : "did NOT arrive",
                now() - asked
            )
        )
        pump(for: 0.15)
    }
    let byMask = left.model.selectionCount
    say("   marked=\(byMask)")
    check(byMask > 300_000 && byMask < 340_000, "4c: mask marked \(byMask), expected about 333,333")
    step("4d invert selection (to ~667k)", limit: 120) {
        app.commands.perform(.invertSelection)
        check(
            pump(upTo: 100) { left.model.selectionCount == total - byMask },
            "4d: invert left \(left.model.selectionCount) marked, expected \(total - byMask)"
        )
        pump(for: 0.15)
    }
    say("   marked=\(left.model.selectionCount)")
    step("4e invert selection (back to ~333k)", limit: 120) {
        app.commands.perform(.invertSelection)
        check(
            pump(upTo: 100) { left.model.selectionCount == byMask },
            "4e: invert left \(left.model.selectionCount) marked, expected \(byMask)"
        )
        pump(for: 0.15)
    }
    say("   marked=\(left.model.selectionCount)")
    step("4f draw with 333k marked") { app.draw(left) }

    // Cursor.
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

    // Validation with ~333k marked.
    step("6a which commands' enabled/checked closures are slow") {
        var costs: [(String, Double)] = []
        for command in app.kernel.commands.all {
            let t0 = now()
            _ = app.kernel.commands.isEnabled(command.id)
            _ = app.kernel.commands.isChecked(command.id)
            costs.append(("\(command.id) \"\(command.title)\"", (now() - t0) * 1_000))
        }
        costs.sort { $0.1 > $1.1 }
        say(String(format: "   all %d commands: %.1f ms; the slowest:", costs.count, costs.reduce(0) { $0 + $1.1 }))
        for (name, cost) in costs.prefix(14) { say(String(format: "     %8.2f ms  %@", cost, name as NSString)) }
        // What a real validation tick does (the bars), and what opening each top-level menu costs.
        let t0 = now()
        app.shell.mainWindow.validateBars()
        say(String(format: "   validateBars (the 0.1 s tick): %.2f ms", (now() - t0) * 1_000))
        for item in menu.items {
            guard let submenu = item.submenu else { continue }
            let t1 = now()
            func walk(_ menu: NSMenu) {
                for item in menu.items {
                    _ = app.shell.mainWindow.validateMenuItem(item)
                    if let sub = item.submenu { walk(sub) }
                }
            }
            walk(submenu)
            say(
                String(
                    format: "     menu '%@' (%d items incl. submenus): %.1f ms",
                    submenu.title as NSString,
                    submenu.items.count,
                    (now() - t1) * 1_000
                )
            )
        }
    }
    step("6 validation x10 (bars, all commands, menu)", limit: 300) {
        var sums = (bars: 0.0, commands: 0.0, menu: 0.0)
        var worst = 0.0
        for _ in 0..<10 {
            let t = app.validateEverything(menu: menu)
            sums.bars += t.bars
            sums.commands += t.commands
            sums.menu += t.menu
            worst = max(worst, t.bars + t.commands + t.menu)
            CFRunLoopRunInMode(.defaultMode, 0.002, true)
        }
        say(
            String(
                format:
                    "   per round: bars %.2f ms, %d commands enabled+checked %.2f ms, menu items %.2f ms; worst round %.2f ms",
                sums.bars * 100,
                app.kernel.commands.all.count,
                sums.commands * 100,
                sums.menu * 100,
                worst * 1_000
            )
        )
    }
    step("6b status line x50 with 333k marked") {
        for _ in 0..<50 {
            left.updateStatus()
            CFRunLoopRunInMode(.defaultMode, 0.002, true)
        }
    }

    // Leave and come back: the remembered listing is shown, the fresh one merged behind.
    step("7a navigate away to a small folder", limit: 120) {
        var away = false
        left.show(small, focus: nil, history: .record) { _ in away = true }
        check(pump(upTo: 100) { away && !left.isLoading }, "7a: leaving did not end")
        pump(for: 0.3)
    }
    step("7b come back (remembered listing + fresh read)", limit: 300) {
        var back = false
        let t0 = now()
        var shown: Double?
        left.show(big, focus: nil, history: .record) { _ in back = true }
        let ok = pump(upTo: 280) {
            if shown == nil, left.model.directory.path == big.path, !left.model.items.isEmpty { shown = now() - t0 }
            return back && !left.isLoading
        }
        check(ok, "7b: coming back did not end")
        say(
            String(
                format: "   rows shown after %.3f s, fresh after %.3f s, rows=%d",
                shown ?? -1,
                now() - t0,
                left.model.items.count
            )
        )
    }

    // 200 quiet reloads while another "program" creates and deletes files; the watcher is live too.
    let churnStop = CancellationFlag()
    let churned = Counter()
    let churn = Thread {
        var round = 0
        while !churnStop.isCancelled {
            let names = (0..<50).map { big.appendingPathComponent("zz-churn-\(round)-\($0).tmp").path }
            for name in names { close(open(name, O_CREAT | O_WRONLY, 0o644)) }
            usleep(20_000)
            for name in names { unlink(name) }
            churned.add(100)
            round += 1
            usleep(20_000)
        }
    }
    step("8 200 quiet reloads + churn + watcher (<=90 s)", limit: 400) {
        churn.start()
        var reads = 0
        var wasLoading = left.isLoading
        var versions = Set<Int>([left.model.listVersion])
        var asked = 0
        let t0 = now()
        var nextAsk = t0
        _ = pump(upTo: 90) {
            let loading = left.isLoading
            if loading, !wasLoading { reads += 1 }
            wasLoading = loading
            versions.insert(left.model.listVersion)
            if asked < 200, now() >= nextAsk {
                left.reload(focus: nil, quietly: true, completion: nil)
                asked += 1
                nextAsk = now() + 0.25
            }
            return asked >= 200 && !loading
        }
        churnStop.cancel()
        say(
            String(
                format: "   asked=%d quiet reloads in %.1f s; readings started=%d; list versions seen=%d; churn ops=%d",
                asked,
                now() - t0,
                reads,
                versions.count,
                churned.count
            )
        )
        check(pump(upTo: 200) { !left.isLoading }, "8: reloading did not settle after the churn stopped")
        // Whatever the churn left behind goes; then the list must match the folder again.
        usleep(100_000)
        MainWatchdog.shared.setPhase("(harness clean-up, not the app)")
        if let leftovers = try? fm.contentsOfDirectory(atPath: big.path).filter({ $0.hasPrefix("zz-churn-") }) {
            leftovers.forEach { unlink(big.appendingPathComponent($0).path) }
        }
    }
    step("8b final quiet reload, list equals folder", limit: 300) {
        pump(for: 1.5)
        var ended = false
        _ = pump(upTo: 120) { !left.isLoading }
        left.reload(focus: nil, quietly: false) { ended = true }
        check(pump(upTo: 200) { ended && !left.isLoading }, "8b: final reload did not end")
        check(
            left.model.items.count == total,
            "8b: after the churn the panel lists \(left.model.items.count), the folder has \(total)"
        )
        check(!left.model.items.contains { $0.name.hasPrefix("zz-churn-") }, "8b: churn files still listed")
    }
    finish("scenario 1: 1,000,000 files in a panel", baseline: baseline, app: app)
}

final class Counter {
    private var value = 0
    private let lock = NSLock()
    func add(_ n: Int = 1) {
        lock.lock()
        value += n
        lock.unlock()
    }
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// MARK: - Scenario 2: a provider that stops answering

func stalled() {
    let work = URL(fileURLWithPath: arguments[2], isDirectory: true)
    let small = work.appendingPathComponent("small")
    makeSmall(small)
    let stall = StallFS()
    for folder in 0..<40 {
        for file in 0..<20 { stall.inner.addFile("/share/folder\(folder)/file\(file).txt", "content \(file)") }
    }
    for file in 0..<400 { stall.inner.addFile("/share/doc\(file).txt", "doc") }
    stall.inner.addFile("/other/place/a.txt")
    let share = stall.inner.url("/share")

    let app = step("start-up") { () -> Running in
        let app = Running(left: small, right: small, home: small, providers: [stall])
        check(app.settle(), "start-up did not settle")
        // The window counts as the active one, so reading ahead is allowed as in real use.
        app.shell.panelCoordinator.isWindowActive = { true }
        return app
    }
    let left = app.left
    let menu = app.shell.makeMainMenu()
    step("idle baseline (1 s)") { pump(for: 1) }
    let baseline = threadCount()
    var log: [(String, Int, Int)] = []
    func note(_ what: String) {
        log.append((what, threadCount(), stall.blockedNow))
        say(
            "   after \(what): threads=\(threadCount()) blocked in provider=\(stall.blockedNow) [\(stall.blockedByMethod)]"
        )
    }

    step("A open the share while it still answers") {
        var done = false
        left.show(share, focus: nil, history: .record) { _ in done = true }
        check(pump(upTo: 20) { done && !left.isLoading }, "A: the share did not open")
        say("   rows=\(left.model.items.count) volume local=\(String(describing: left.model.volume?.isLocal))")
    }
    note("open")

    stall.isStalled = true
    say("---- the provider stops answering ----")
    func act(_ name: String, wait seconds: Double = 0.4, _ body: () -> Void) {
        step("B " + name, limit: 30) {
            body()
            pump(for: seconds)
        }
        note(name)
    }
    act("cursor moves over 40 folders (read-ahead)") {
        for row in 1...40 {
            left.model.moveCursor(to: row)
            pump(for: 0.05)
        }
    }
    act("refresh (Cmd+R)") { app.commands.perform(.reread) }
    act("validation x5") { for _ in 0..<5 { _ = app.validateEverything(menu: menu) } }
    act("enter folder under cursor (Return)") {
        left.model.moveCursor(to: 3)
        app.commands.perform(.open)
    }
    act("go to parent") { app.commands.perform(.goToParent) }
    act("go back") { app.commands.perform(.goBack) }
    act("new tab") { app.commands.perform(.newTab) }
    act("navigate the new tab to another stalled folder") {
        left.show(stall.inner.url("/other/place"), focus: nil, history: .record, completion: nil)
    }
    act("previous tab") { app.commands.perform(.previousTab) }
    act("next tab") { app.commands.perform(.nextTab) }
    act("quick filter typed") {
        left.showQuickFilter()
        left.quickFilterEdited("doc1")
        pump(for: 0.3)
        left.removeQuickFilter()
    }
    act("sort by size") { app.commands.perform(.sortBySize) }
    act("select all + status line") {
        app.commands.perform(.selectAll)
        left.updateStatus()
    }
    act("space on a folder (size calculation)") {
        left.model.moveCursor(to: 2)
        app.commands.perform(.toggleSelectionWithSize)
    }
    act("application deactivates / activates") {
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        pump(for: 0.2)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    }
    act("switch panel (Tab) and back") {
        app.commands.perform(.focusTarget)
        pump(for: 0.1)
        app.commands.perform(.focusTarget)
    }
    act("right panel: target = source") {
        app.commands.perform(.focusTarget)
        app.commands.perform(.targetEqualsSource)
        pump(for: 0.2)
        app.commands.perform(.focusTarget)
    }
    act("draw list") { app.draw(left) }
    act("validation x5 again") { for _ in 0..<5 { _ = app.validateEverything(menu: menu) } }
    act("close tab") { app.commands.perform(.closeTab) }
    act("navigate away to a local folder (both panels)", wait: 1.0) {
        left.show(small, focus: nil, history: .record, completion: nil)
        app.right.show(small, focus: nil, history: .record, completion: nil)
        for index in stride(from: left.tabs.count - 1, through: 0, by: -1)
        where left.tabs.count > 1 && left.tabs.tabs[index] !== left.model { _ = left.tabs.closeTab(at: index) }
    }
    let stillBlocked = step("C wait 3 s after leaving; who is still blocked") { () -> Int in
        pump(for: 3)
        return stall.blockedNow
    }
    note("3 s after leaving the share")
    let threadsWhileStalled = threadCount()
    say(
        "   blocked provider calls that did not end although the panel left: \(stillBlocked); threads now \(threadsWhileStalled) (baseline \(baseline))"
    )

    let (calls, main) = stall.snapshotCalls()
    say(
        "\nPROVIDER CALLS (all threads): "
            + calls.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
    )
    say(
        "PROVIDER CALLS MADE ON THE MAIN THREAD WHILE THE PROVIDER WAS NOT ANSWERING (each would freeze the window for as long as the server is silent): \(main.isEmpty ? "none" : "")"
    )
    for (method, entry) in main.sorted(by: { $0.key < $1.key }) {
        say("  * \(method) x\(entry.count); first stack:")
        for line in entry.stack.dropFirst(2).prefix(22) { say("      " + line) }
    }
    check(
        main.isEmpty,
        "2: \(main.count) kinds of provider calls reached the main thread while the provider stalled: \(main.keys.sorted().joined(separator: ", "))"
    )

    // E. A user who keeps pressing Refresh on the dead share: does the rest of the program still work?
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
        let t0 = now()
        app.right.show(other, focus: nil, history: .record) { _ in done = true }
        if pump(upTo: 20, until: { done && !app.right.isLoading }) { localLoad = now() - t0 }
    }
    say(
        localLoad.map {
            String(
                format: "   local folder (300 files) opened in %.3f s while %d provider calls are blocked",
                $0,
                stall.blockedNow
            )
        }
            ?? "   LOCAL FOLDER DID NOT OPEN WITHIN 20 s while \(stall.blockedNow) provider calls are blocked (threads=\(threadCount()))"
    )
    check(
        localLoad != nil && localLoad! < 2,
        "2/E: with \(stall.blockedNow) calls blocked in a dead provider, a local folder took \(localLoad.map { String(format: "%.1f s", $0) } ?? "more than 20 s") to open"
    )
    note("local load")

    step("D release the stall; threads end") {
        stall.release()
        pump(for: 0.5)
    }
    let after = waitForThreads(atMost: baseline + 2, upTo: 8, onMain: true)
    say(
        "   blocked now=\(stall.blockedNow), most blocked at once=\(stall.mostBlockedAtOnce); threads baseline=\(baseline) while stalled (after leaving)=\(threadsWhileStalled) after release=\(after)"
    )
    check(stall.blockedNow == 0, "2: \(stall.blockedNow) provider calls still blocked after release")
    finish("scenario 2: stalled provider", baseline: baseline, app: app)
}

// MARK: - Scenario 8: a flood of changes in a watched folder

func flood() {
    let work = URL(fileURLWithPath: arguments[2], isDirectory: true)
    let files = arguments.count > 3 ? Int(arguments[3])! : 20_000
    let rate = arguments.count > 4 ? Int(arguments[4])! : 5_000
    let seconds = arguments.count > 5 ? Double(arguments[5])! : 20
    let small = work.appendingPathComponent("small")
    let watched = work.appendingPathComponent("flood")
    MainWatchdog.shared.setPhase("(harness set-up, not the app)")
    makeSmall(small)
    try? fm.removeItem(at: watched)
    try! fm.createDirectory(at: watched, withIntermediateDirectories: true)
    for index in 0..<files {
        close(
            open(
                watched.appendingPathComponent(String(format: "base%06d.dat", index)).path,
                O_CREAT | O_WRONLY,
                0o644
            )
        )
    }

    let app = step("start-up") { () -> Running in
        let app = Running(left: watched, right: small, home: small)
        check(app.settle(), "start-up did not settle")
        return app
    }
    let left = app.left
    step("idle baseline (2 s)") { pump(for: 2) }
    let baseline = threadCount()
    say("   watched folder: \(left.model.items.count) rows")
    let footprintBefore = footprintMB()

    let stop = CancellationFlag()
    let operations = Counter()
    let flooder = Thread {
        var random = Random(seed: 8)
        var live: [String] = []
        var serial = 0
        let perBatch = max(1, rate / 100)
        let started = now()
        var batch = 0
        while !stop.isCancelled {
            for _ in 0..<perBatch {
                let kind = Int.random(in: 0..<3, using: &random)
                if kind == 0 || live.count < 200 {
                    serial += 1
                    let name = watched.appendingPathComponent("flood-\(serial).tmp").path
                    close(open(name, O_CREAT | O_WRONLY, 0o644))
                    live.append(name)
                } else if kind == 1 {
                    unlink(live.remove(at: Int.random(in: 0..<live.count, using: &random)))
                } else {
                    let index = Int.random(in: 0..<live.count, using: &random)
                    serial += 1
                    let name = watched.appendingPathComponent("flood-\(serial)-renamed.tmp").path
                    rename(live[index], name)
                    live[index] = name
                }
            }
            operations.add(perBatch)
            batch += 1
            // Keeps the pace: one batch per 10 ms.
            let ahead = started + Double(batch) * 0.01 - now()
            if ahead > 0 { usleep(useconds_t(ahead * 1e6)) }
        }
    }

    var reads = 0
    var versions = Set<Int>([left.model.listVersion])
    let cpu0 = cpuSeconds()
    step(String(format: "flood: %d ops/s for %.0f s in %d-file folder", rate, seconds, files), limit: seconds + 120) {
        flooder.start()
        var wasLoading = false
        let end = now() + seconds
        _ = pump(upTo: seconds + 5) {
            let loading = left.isLoading
            if loading, !wasLoading { reads += 1 }
            wasLoading = loading
            versions.insert(left.model.listVersion)
            return now() >= end
        }
        stop.cancel()
    }
    let cpuFlood = cpuSeconds() - cpu0
    say(
        String(
            format:
                "   achieved %d operations (%.0f/s); readings of the folder started=%d; list versions=%d; process CPU %.1f s over %.0f s (%.0f%% of one core, includes the flooding thread itself)",
            operations.count,
            Double(operations.count) / seconds,
            reads,
            versions.count,
            cpuFlood,
            seconds,
            cpuFlood / seconds * 100
        )
    )
    step("settle after flood (3 s + until quiet)", limit: 120) {
        pump(for: 3)
        check(pump(upTo: 100) { !left.isLoading }, "8: panel still reading 100 s after the flood")
        pump(for: 1.5)
        _ = pump(upTo: 100) { !left.isLoading }
    }
    let onDisk = Set((try? fm.contentsOfDirectory(atPath: watched.path)) ?? [])
    let shown = Set(left.model.items.map(\.name))
    check(
        onDisk == shown,
        "8: after the flood the panel shows \(shown.count) names, the folder has \(onDisk.count) (missing \(onDisk.subtracting(shown).count), stale \(shown.subtracting(onDisk).count))"
    )
    say(
        String(
            format: "   after settle: panel rows=%d, folder entries=%d, equal=%@; footprint before=%.0fMB after=%.0fMB",
            shown.count,
            onDisk.count,
            "\(onDisk == shown)",
            footprintBefore,
            footprintMB()
        )
    )
    MainWatchdog.shared.setPhase("(harness clean-up, not the app)")
    try? fm.removeItem(at: watched)
    finish("scenario 8: watcher flood", baseline: baseline, app: app)
}

switch mode {
case "million": million()
case "stalled": stalled()
case "flood": flood()

default:
    say("unknown mode")
    exit(2)
}
