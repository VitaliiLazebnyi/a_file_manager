import AFMContracts
import AFMKernel
import AppKit
import StandardPlugins
import TestSupport
import Testing

@testable import AFMShell

/// Returning to a folder on a slow server, and entering the folder under the cursor: the
/// listing cache ("show old, refresh behind") and the read-ahead, through the real window.
/// The memory file system plays the server: `listStartDelay` is how long it takes to answer,
/// `listRequests` how often it was asked.
extension Application {
    /// A share with a few entries, and a panel that has been in `/nas` and is back in `/`
    /// with the cursor on `nas`, so the folder is remembered.
    func startWithARememberedFolder(delay: TimeInterval = 0.8) async -> Running {
        memory.addFile("/nas/a.txt", "a")
        memory.addFile("/nas/b.txt", "bb")
        memory.addFile("/nas/sub/in.txt", "12345")
        memory.listStartDelay = delay
        let app = await start()
        app.left.show(memory.url("/nas"))
        await settle(app)
        app.left.show(memory.url("/"), focus: "nas")
        await settle(app)
        return app
    }

    func remembered(_ app: Running, _ path: String) -> [String]? {
        app.kernel.listingCache.entry(for: memory.url(path), showHidden: false)?.listing.items.map(\.name)
    }

    func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: Show old, refresh behind

    @Test func aRememberedFolderIsShownAtOnceAndReadAfreshBehind() async {
        // The server is slow enough that everything below that has to happen before it
        // answers does, however busy the machine is.
        let app = await startWithARememberedFolder(delay: 3)
        defer { app.stop() }
        #expect(app.left.model.cursorItem?.name == "nas" && remembered(app, "/nas") == ["sub", "a.txt", "b.txt"])
        // Meanwhile the folder changes on the server.
        memory.addFile("/nas/new.txt")
        memory.removeTree("/nas/b.txt")

        app.commands.perform(.open)
        // The server has not answered (it takes seconds), but the old listing is in the
        // window, in the same turn of the main thread.
        #expect(app.left.model.directory.path == "/nas" && app.names(app.left) == ["sub", "a.txt", "b.txt"])
        #expect(app.left.tableView.numberOfRows == 4)
        #expect(app.left.model.isRefreshing && !app.left.model.isComplete && !app.left.model.isOpening)
        #expect(app.left.isLoading && app.left.showsActivity)
        #expect(app.left.statusLineText == "Refreshing…   0 k / 0 k in 0 / 2 file(s), 0 / 1 dir(s)")
        #expect(app.left.model.backLocation?.path == "/")
        // "Everything" has to wait for the fresh listing; what is named can be worked with.
        #expect(
            !app.commands.isEnabled(.selectAll) && !app.commands.isEnabled(.invertSelection)
                && !app.commands.isEnabled(.selectGroup))
        app.cursor(app.left, on: "sub")
        #expect(app.commands.isEnabled(.copy) && app.commands.isEnabled(.delete) && app.commands.isEnabled(.goToParent))
        #expect(press(app, 49) && app.left.model.selection == ["sub"])  // Space: mark and measure
        let measured = await wait(upTo: 2.5) { app.left.model.cursorItem?.computedSize == 5 }
        #expect(measured && app.left.model.isRefreshing)
        app.cursor(app.left, on: "a.txt")
        #expect(press(app, 49) && app.left.model.selection == ["sub", "a.txt"])

        // The fresh listing arrives: the list changes where the folder did, nothing else moves.
        await settle(app)
        #expect(app.names(app.left) == ["sub", "a.txt", "new.txt"] && app.left.tableView.numberOfRows == 4)
        #expect(app.left.model.cursorItem?.name == "a.txt" && app.left.model.selection == ["sub", "a.txt"])
        #expect(app.left.model.items.first?.computedSize == 5)
        #expect(
            app.left.model.isComplete && !app.left.model.isRefreshing && !app.left.isLoading && !app.left.showsActivity)
        #expect(app.left.statusLineText == "0 k / 0 k in 1 / 2 file(s), 1 / 1 dir(s)")
        #expect(app.commands.isEnabled(.selectAll) && app.commands.isEnabled(.invertSelection))
        // The server was asked once for the first visit and once for the refresh.
        #expect(memory.listRequests(for: "/nas") == 2)
        #expect(remembered(app, "/nas") == ["sub", "a.txt", "new.txt"])
        #expect(app.left.model.backLocation?.path == "/" && app.left.model.forwardLocation == nil)
    }

    @Test func readingAgainBringsWhatIsRememberedUpToDate() async {
        let app = await startWithARememberedFolder(delay: 0.3)
        defer { app.stop() }
        app.commands.perform(.open)
        await settle(app)
        // A change by another program, noticed the way a watcher event or the activation of
        // the program is: a quiet reload.
        memory.addFile("/nas/later.txt")
        app.shell.panelCoordinator.reloadChangedPanels()
        // A folder that was read a moment ago is read again after a pause, not at once.
        await rest(app)
        #expect(app.names(app.left).contains("later.txt") && remembered(app, "/nas")?.contains("later.txt") == true)
    }

    @Test func aRememberedFolderInAnotherOrderIsSortedInTheBackground() async {
        let app = await startWithARememberedFolder(delay: 3)
        defer { app.stop() }
        app.left.model.setSort(ListOrder(key: .name, descending: true))
        app.commands.perform(.open)
        // Not in the same breath (the sorting is not done on the main thread), but long before
        // the server answers.
        let shown = await wait(upTo: 2.5) { app.left.model.directory.path == "/nas" }
        #expect(shown && app.names(app.left) == ["sub", "b.txt", "a.txt"] && app.left.model.isRefreshing)
        await settle(app)
        #expect(app.names(app.left) == ["sub", "b.txt", "a.txt"] && app.left.model.isComplete)
        #expect(
            app.kernel.listingCache.entry(for: memory.url("/nas"), showHidden: false)?.order
                == ListOrder(key: .name, descending: true))
    }

    @Test func aRefreshThatFailsLeavesTheFolderAndForgetsIt() async {
        let app = await startWithARememberedFolder()
        defer { app.stop() }
        memory.unreadable = ["/nas"]
        app.commands.perform(.open)
        #expect(app.left.model.directory.path == "/nas" && app.left.model.isRefreshing)
        await settle(app)
        _ = await wait(upTo: 2) { !ui.log.isEmpty }
        // As after any reading that failed: back where the panel was, and the user is told.
        #expect(app.left.model.directory.path == "/" && app.left.model.cursorItem?.name == "nas")
        #expect(app.left.model.isComplete && !app.left.model.isRefreshing && !app.left.showsActivity)
        #expect(app.left.model.forwardLocation == nil && ui.log == ["inform: The folder cannot be read!"])
        #expect(app.kernel.listingCache.age(of: memory.url("/nas"), showHidden: false) == nil)
        // The next attempt is an ordinary reading.
        memory.unreadable = []
        app.commands.perform(.open)
        #expect(app.left.model.directory.path == "/")
        await settle(app)
        #expect(app.left.model.directory.path == "/nas" && app.names(app.left) == ["sub", "a.txt", "b.txt"])
    }

    @Test func aFolderThatFailsWhileAnotherReadingOvertookTheOpeningOneGoesBackOnceAndIsReportedOnce() async {
        memory.addFile("/nas/a.txt", "a")
        // The server does not answer until the test lets it: nothing here depends on how
        // long anything takes.
        memory.stallsListings = true
        memory.stalledPaths = ["/nas"]
        memory.unreadable = ["/nas"]
        let app = await start()
        defer { app.stop() }
        let before = app.left.model.directory
        app.left.show(memory.url("/nas"))
        // Slow: the panel enters the folder, empty, and waits.
        let asked = await wait(upTo: 30) { memory.stalledListings(of: "/nas") == 1 }
        let opened = await wait(upTo: 30) { app.left.model.isOpening }
        #expect(asked && opened && app.left.model.directory.path == "/nas")
        // Reading it again (a refresh) overtakes the first reading, which had the way back.
        app.commands.perform(.reread)
        let again = await wait(upTo: 30) {
            memory.listRequests(for: "/nas") == 2 && memory.stalledListings(of: "/nas") == 1
        }
        #expect(again && app.left.isLoading)
        // Now the server answers: the folder cannot be read.
        memory.releaseStalls()
        let done = await wait(upTo: 30) { !app.left.isLoading }
        #expect(done)
        // The message comes from the run loop, a turn after the reading has ended.
        _ = await wait(upTo: 10) { !ui.log.isEmpty }
        await pause(0.5)
        // Back where it came from; told once, and not asked again.
        #expect(
            app.left.model.directory.isSameLocation(as: before) && app.left.model.isListed && app.left.model.isComplete)
        #expect(ui.log.filter { $0 == "inform: The folder cannot be read!" }.count == 1)
        #expect(memory.listRequests(for: "/nas") == 2)
    }

    @Test func aReloadThatIsTurnedAwayWhileTheFolderIsReadIsMadeUpForAfterwards() async {
        memory.addFile("/nas/a.txt", "a")
        let app = await start()
        defer { app.stop() }
        // Long enough that the reading is still under way when this test gets its next turn,
        // however busy the machine is.
        memory.listStartDelay = 1.5
        app.left.show(memory.url("/nas"))
        let reading = await wait { memory.listRequests(for: "/nas") == 1 }
        #expect(reading && app.left.isLoading)
        // The folder changes while it is read; the watcher asks for a quiet reload.
        app.left.reload(focus: nil, quietly: true, completion: nil)
        // Made up for after the reading, and after the pause that follows a reading.
        #expect(app.left.hasPendingReread)
        await rest(app)
        #expect(memory.listRequests(for: "/nas") == 2 && !app.left.isLoading)
    }

    @Test func theCompletionOfAReadingThatWasOvertakenHearsOfIt() async {
        memory.addFile("/nas/a.txt", "a")
        memory.addFile("/nas/sub/in.txt", "1")
        memory.listStartDelay = 0.3
        let app = await start()
        defer { app.stop() }
        var results: [String] = []
        app.left.show(memory.url("/nas"), focus: nil, history: .record) { results.append("first:\($0)") }
        app.left.show(memory.url("/nas/sub"), focus: nil, history: .record) { results.append("second:\($0)") }
        await settle(app)
        #expect(results == ["first:false", "second:true"] && app.left.model.directory.path == "/nas/sub")
    }

    @Test func aFileThatVanishedMeanwhileGivesTheUsualError() async {
        let app = await startWithARememberedFolder()
        defer { app.stop() }
        memory.removeTree("/nas/a.txt")
        app.commands.perform(.open)
        // The remembered listing still names the file; copying it is tried and fails properly.
        app.cursor(app.left, on: "a.txt")
        #expect(app.left.model.cursorItem?.name == "a.txt")
        ui.promptAnswers = [.accept]
        ui.choiceAnswers = [0]
        app.commands.perform(.copy)
        await settle(app)
        #expect(ui.log.last == "choose: Error with a.txt / mem:/nas/a.txt does not exist any more!")
        #expect(!box.exists("B/a.txt"))
        // The job's own re-reading has put the list right.
        #expect(app.names(app.left) == ["sub", "b.txt"] && app.left.model.isComplete && !app.left.model.isRefreshing)
    }

    @Test func anOperationInAFolderThatIsNotShownMakesItForgotten() async {
        let app = await startWithARememberedFolder(delay: 0.3)
        defer { app.stop() }
        // /nas/sub is visited, so it is remembered, and left again.
        app.left.show(memory.url("/nas/sub"))
        await settle(app)
        app.commands.perform(.goToParent)
        await settle(app)
        #expect(app.left.model.directory.path == "/nas" && remembered(app, "/nas/sub") == ["in.txt"])
        // A copy into it, typed as the target, while no panel shows it.
        app.cursor(app.left, on: "a.txt")
        ui.promptAnswers = [.text("/nas/sub/")]
        app.commands.perform(.copy)
        await settle(app)
        #expect(memory.exists("/nas/sub/a.txt"))
        #expect(app.kernel.listingCache.age(of: memory.url("/nas/sub"), showHidden: false) == nil)
        // Entering it is therefore an ordinary reading, with the new file in it.
        let before = memory.listRequests(for: "/nas/sub")
        app.cursor(app.left, on: "sub")
        app.commands.perform(.open)
        #expect(app.left.model.directory.path == "/nas")
        await settle(app)
        #expect(app.names(app.left) == ["a.txt", "in.txt"] && memory.listRequests(for: "/nas/sub") == before + 1)
    }

    @Test func switchedOffNothingIsRemembered() async {
        settings.set(false, forKey: ListingCache.settingsKey)
        let app = await startWithARememberedFolder(delay: 0.3)
        defer { app.stop() }
        #expect(remembered(app, "/nas") == nil)
        app.commands.perform(.open)
        #expect(app.left.model.directory.path == "/")
        await settle(app)
        #expect(app.left.model.directory.path == "/nas" && memory.listRequests(for: "/nas") == 2)
    }

    // MARK: Reading ahead

    /// A share (not a local volume) with two folders and a file, shown in the left panel of a
    /// window that counts as active.
    func startOnAShare(delay: TimeInterval = 0) async -> Running {
        memory.isLocal = false
        for index in 0..<3 { memory.addFile("/nas/one/file\(index).txt") }
        memory.addFile("/nas/two/y.txt")
        memory.addFile("/nas/file.txt")
        memory.listStartDelay = delay
        let app = await start()
        app.shell.panelCoordinator.isWindowActive = { true }
        app.left.show(memory.url("/nas"))
        await settle(app)
        return app
    }

    var dwell: TimeInterval { ReadAhead.dwell }

    @Test func theFolderUnderTheCursorIsReadAheadAfterAMoment() async {
        let app = await startOnAShare()
        defer { app.stop() }
        let cache = app.kernel.listingCache
        // On [..] and on a file nothing is read.
        #expect(app.left.model.cursorIsOnParentRow)
        await pause(dwell + 0.3)
        app.cursor(app.left, on: "file.txt")
        await pause(dwell + 0.3)
        #expect(memory.listRequests == ["/nas"])

        // On a folder: not at once, but once the cursor has rested there.
        app.cursor(app.left, on: "one")
        await pause(dwell / 2)
        #expect(memory.listRequests(for: "/nas/one") == 0)
        let read = await wait(upTo: 600) { cache.age(of: self.memory.url("/nas/one"), showHidden: false) != nil }
        #expect(read && memory.listRequests(for: "/nas/one") == 1)
        // Enter finds it there.
        app.commands.perform(.open)
        #expect(app.left.model.directory.path == "/nas/one" && app.names(app.left).count == 3)
        await settle(app)
        app.commands.perform(.goToParent)
        await settle(app)

        // What was read a moment ago is not read ahead again.
        let requests = memory.listRequests(for: "/nas/one")
        #expect(app.left.model.cursorItem?.name == "one")
        app.cursor(app.left, on: "file.txt")
        app.cursor(app.left, on: "one")
        await pause(dwell + 0.3)
        #expect(memory.listRequests(for: "/nas/one") == requests && memory.listRequests(for: "/nas/two") == 0)
    }

    @Test func nothingIsReadAheadOnALocalVolumeOrInAnInactiveWindow() async {
        let app = await startOnAShare()
        defer { app.stop() }
        // The window is not the active one.
        app.shell.panelCoordinator.isWindowActive = { false }
        app.cursor(app.left, on: "one")
        await pause(dwell + 0.3)
        #expect(memory.listRequests(for: "/nas/one") == 0)
        // The same folders on a local volume.
        app.shell.panelCoordinator.isWindowActive = { true }
        memory.isLocal = true
        app.commands.perform(.reread)
        await settle(app)
        #expect(app.left.model.volume?.isLocal == true)
        app.cursor(app.left, on: "two")
        app.cursor(app.left, on: "one")
        await pause(dwell + 0.3)
        #expect(memory.listRequests(for: "/nas/one") == 0 && memory.listRequests(for: "/nas/two") == 0)
        #expect(!app.shell.panelCoordinator.readAhead.isReading)
    }

    @Test func readingAheadCanBeSwitchedOff() async {
        settings.set(false, forKey: ReadAhead.settingsKey)
        let app = await startOnAShare()
        defer { app.stop() }
        app.cursor(app.left, on: "one")
        await pause(dwell + 0.3)
        #expect(memory.listRequests(for: "/nas/one") == 0)
    }

    @Test func movingTheCursorCancelsAReadAheadAndEnterJoinsOne() async {
        let app = await startOnAShare(delay: 2.5)
        defer { app.stop() }
        let cache = app.kernel.listingCache
        app.cursor(app.left, on: "one")
        let started = await wait(upTo: 600) { self.memory.listRequests(for: "/nas/one") == 1 }
        #expect(started && app.shell.panelCoordinator.readAhead.isReading)
        // The cursor moves on while the server is still busy with /nas/one: that reading is
        // given up, and /nas/two has to wait until it has come back.
        app.cursor(app.left, on: "two")
        let second = await wait(upTo: 15) { self.memory.listRequests(for: "/nas/two") == 1 }
        #expect(second && cache.age(of: memory.url("/nas/one"), showHidden: false) == nil)

        // Enter while /nas/two is on its way: the panel waits for that reading.
        app.commands.perform(.open)
        #expect(app.left.model.directory.path == "/nas" && app.left.isLoading)
        let entered = await wait(upTo: 2) { app.left.model.directory.path == "/nas/two" && app.left.model.isOpening }
        #expect(entered && app.left.statusLineText == "Reading mem:/nas/two…")
        await settle(app)
        #expect(app.names(app.left) == ["y.txt"] && app.left.model.isComplete && !app.left.model.isRefreshing)
        #expect(app.left.model.backLocation?.path == "/nas")
        // The server was asked for it once, and never for two folders at the same time.
        await pause(0.3)
        #expect(memory.listRequests(for: "/nas/two") == 1 && memory.mostListingsAtOnce == 1)
        #expect(memory.listRequests == ["/nas", "/nas/one", "/nas/two"])
    }

    @Test func aFolderThatCouldNotBeReadAheadIsLeftAlone() async {
        memory.addDirectory("/nas/locked")
        memory.unreadable = ["/nas/locked"]
        let app = await startOnAShare()
        defer { app.stop() }
        app.cursor(app.left, on: "locked")
        // Tried, and come back with its failure (a reading that the cursor leaves while it is
        // still under way is stopped, which is no failure of the folder).
        let tried = await wait(upTo: 600) {
            self.memory.listRequests(for: "/nas/locked") == 1 && !app.shell.panelCoordinator.readAhead.isReading
        }
        #expect(tried)
        app.cursor(app.left, on: "file.txt")
        app.cursor(app.left, on: "locked")
        await pause(dwell + 0.3)
        // Tried once, quietly: no second attempt, nothing said to the user.
        #expect(memory.listRequests(for: "/nas/locked") == 1 && ui.log.isEmpty)
    }

    @Test func nothingIsReadAheadWhileAJobRuns() async {
        let app = await startOnAShare()
        defer { app.stop() }
        app.kernel.jobs.run(title: "Busy", work: { _ in Thread.sleep(forTimeInterval: 1.0) }, completion: { _ in })
        // Cursor keys work during a job.
        app.cursor(app.left, on: "one")
        await pause(dwell + 0.3)
        #expect(app.kernel.jobs.isBusy && memory.listRequests(for: "/nas/one") == 0)
        // When the job has ended, the folder the cursor still rests on gets its turn.
        let read = await wait(upTo: 4) { self.memory.listRequests(for: "/nas/one") == 1 }
        #expect(read && !app.kernel.jobs.isBusy)
    }

    @Test func aJobThatStartsStopsAReadAhead() async {
        let app = await startOnAShare(delay: 0.8)
        defer { app.stop() }
        app.cursor(app.left, on: "one")
        let started = await wait(upTo: 600) { self.memory.listRequests(for: "/nas/one") == 1 }
        #expect(started)
        app.kernel.jobs.run(title: "Busy", work: { _ in Thread.sleep(forTimeInterval: 1.2) }, completion: { _ in })
        // The server still answers the request it has, but the answer is not used.
        let over = await wait(upTo: 600) { !app.shell.panelCoordinator.readAhead.isReading }
        #expect(over && app.kernel.jobs.isBusy)
        #expect(app.kernel.listingCache.age(of: memory.url("/nas/one"), showHidden: false) == nil)
    }
}
