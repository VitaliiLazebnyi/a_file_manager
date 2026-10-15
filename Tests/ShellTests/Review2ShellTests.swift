import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// What review round 2 asked of the window shell, through the real program: nothing waits on
/// the main thread, and a job or a share that does not answer holds up only itself.
@MainActor
@Suite(.serialized)
internal struct Review2ShellTests {
    private let program: PanelProgram

    /// The program's folders.
    internal init() throws {
        program = try PanelProgram(rightFile: "one.txt", contents: "old")
    }

    /// Watching is set up off the main thread and never twice for a folder that has not
    /// answered; a watch that is wanted is kept, and what it reports reads the folder again
    /// (S010, S032).
    @Test
    internal func watchingIsSetUpOffTheMainThreadAndNeverTwiceForAFolderThatHasNotAnswered() async {
        let watched = PanelWatchedFileSystem()
        watched.inner.addFile("/w/a.txt")
        watched.holdsWatches = true
        let app = await program.start(plugins: program.standardPlugins, fileSystems: [watched])
        defer {
            watched.holdsWatches = false
            app.stop()
        }
        app.left.show(watched.url("/w"))
        await program.settle(app)
        // The folder is on screen although its file system has not come back from `watch`.
        #expect(app.names(app.left) == ["a.txt"])
        #expect(await PanelWait.until { watched.watches.count == 1 })
        #expect(watched.watches.allSatisfy { $0.path == "/w" && !$0.onMain })
        // Leaving and coming back while that call is still out starts no second one.
        for location in [program.box.url("A"), watched.url("/w"), program.box.url("A")] {
            app.left.show(location)
            await program.settle(app)
        }
        #expect(watched.watches.count == 1 && watched.livingWatches == 0)
        // The call comes back for a folder nobody shows any more: the watch is let go of.
        watched.holdsWatches = false
        #expect(await PanelWait.until { watched.endedWatches == 1 } && watched.livingWatches == 0)
        // A watch that is wanted is kept, and what it reports reads the folder again.
        app.left.show(watched.url("/w"))
        await program.settle(app)
        #expect(await PanelWait.until { watched.livingWatches == 1 })
        #expect(watched.watches.count == 2 && watched.watches.allSatisfy { !$0.onMain })
        await program.rest(app)
        watched.inner.addFile("/w/b.txt")
        watched.reportChange(of: "/w")
        #expect(await PanelWait.until { app.names(app.left) == ["a.txt", "b.txt"] })
        #expect(Set(watched.watches.map(\.path)) == ["/w"])
    }

    /// Places are asked for off the main thread; the drive bar and the volume list show what
    /// the store knows, without asking themselves.
    @Test
    internal func placesAreAskedForOffTheMainThread() async {
        let watched = PanelWatchedFileSystem()
        let app = await program.start(plugins: program.standardPlugins, fileSystems: [watched])
        defer { app.stop() }
        let places = app.shell.panelCoordinator.places
        #expect(await PanelWait.until { places.isComplete })
        #expect(places.all.contains { $0.name == "Watched" } && places.all.contains { $0.name == "Memory" })
        #expect(!watched.placesAskedOnMain.isEmpty && watched.placesAskedOnMain.allSatisfy { !$0 })
        let asked = watched.placesAskedOnMain.count
        app.shell.mainWindow.driveBar.rebuild()
        #expect(app.shell.mainWindow.driveBar.places.map(\.name) == places.all.map(\.name))
        #expect(app.shell.panelCoordinator.placesForVolumeList(of: app.left).map(\.name) == places.all.map(\.name))
        #expect(await PanelWait.until { watched.placesAskedOnMain.count > asked })
        #expect(watched.placesAskedOnMain.allSatisfy { !$0 })
    }

    /// A job that does not stop can be left behind, the queue moves on, and its completion
    /// still runs when the system lets it go (S005, S007, S016, S037, S046).
    @Test
    internal func aJobThatDoesNotStopCanBeLeftBehindAndTheQueueMovesOn() async {
        let app = await program.start()
        defer { app.stop() }
        let service = app.shell.jobService
        service.patience = 0.05
        let release = DispatchSemaphore(value: 0)
        let thread = Shared("")
        var log: [String] = []
        service.run(
            title: "Stuck",
            work: { _ -> String in
                thread.value = Thread.current.name ?? ""
                release.wait()
                return "late"
            },
            completion: { log.append($0) }
        )
        service.run(title: "Next", work: { _ in "next" }, completion: { log.append($0) })
        // Asked twice: the first time the user keeps waiting.
        program.interaction.choiceAnswers = [1, 0]
        service.cancelCurrent()
        #expect(await PanelWait.until { !service.isBusy })
        #expect(log == ["next"] && service.abandonedCount == 1 && app.commands.isEnabled(.goToParent))
        #expect(
            program.interaction.log.count == 2
                && program.interaction.log.allSatisfy { $0.hasPrefix("choose: “Stuck” does not stop.") }
        )
        // Its own thread, not one of the system's shared pool.
        #expect(thread.value == "afm.job")
        release.signal()
        #expect(await PanelWait.until { log.count == 2 })
        #expect(log == ["next", "late"] && service.abandonedCount == 0 && !service.isBusy)
    }

    /// A job that does not stop does not keep the program from quitting; with nothing running,
    /// quitting asks nothing.
    @Test
    internal func aJobThatDoesNotStopDoesNotKeepTheProgramFromQuitting() async {
        let app = await program.start()
        let release = DispatchSemaphore(value: 0)
        defer {
            release.signal()
            app.stop()
        }
        app.kernel.jobs.run(title: "Stuck", work: { _ in release.wait() }, completion: { _ in })
        program.interaction.choiceAnswers = [1, 0]
        var replies: [Bool] = []
        app.shell.stopJobsToQuit(patience: 0.05) { replies.append($0) }
        #expect(replies.isEmpty)
        #expect(await PanelWait.until { !replies.isEmpty })
        #expect(replies == [true] && app.kernel.jobs.isBusy)
        #expect(
            program.interaction.log.count == 2
                && program.interaction.log.allSatisfy { $0.hasPrefix("choose: An operation does not stop.") }
        )
        release.signal()
        await program.settle(app)
        app.shell.stopJobsToQuit { replies.append($0) }
        #expect(replies == [true, true] && program.interaction.log.count == 2)
    }

    /// The job service says it is idle before the last completion runs; a question from the
    /// main thread is answered there instead of waiting for itself.
    @Test
    internal func theServiceSaysItIsIdleBeforeTheLastCompletionRuns() async {
        let app = await program.start()
        defer { app.stop() }
        let service = app.shell.jobService
        var states: [String] = []
        let told = service.onBusyChanged
        service.onBusyChanged = {
            states.append("busy \(service.isBusy)")
            told?()
        }
        service.run(
            title: "One",
            work: { _ in 1 },
            completion: { _ in states.append("first done, busy \(service.isBusy)") }
        )
        service.run(
            title: "Two",
            work: { _ in 2 },
            completion: { _ in states.append("second done, busy \(service.isBusy)") }
        )
        await program.settle(app)
        await PanelWait.until { states.count == 4 }
        #expect(states == ["busy true", "first done, busy true", "busy false", "second done, busy false"])
        let sheet = ProgressSheet(title: "", cancellation: CancellationFlag())
        #expect(sheet.ask { 7 } == 7)
    }

    /// A key does not bring the whole menu bar up to date; the key of a command checks one
    /// entry, also on a keyboard that writes another script (S004, S033, S034, S072).
    @Test
    internal func aKeyDoesNotBringTheWholeMenuBarUpToDate() async throws {
        let app = await program.start()
        defer { app.stop() }
        let menu = app.shell.makeMainMenu()
        let keys = try #require(MenuBuilder.keyAnswers(of: menu))
        let down = String(try #require(UnicodeScalar(NSDownArrowFunctionKey)))
        for event in [
            PanelProgram.key(0, "a", []), PanelProgram.key(125, down, []),
            PanelProgram.key(38, "j", [.command, .control, .option])
        ] {
            #expect(!menu.performKeyEquivalent(with: event))
        }
        #expect(keys.lookups > 0 && keys.validations == 0)
        let lookups = keys.lookups
        _ = menu.performKeyEquivalent(
            with: PanelProgram.key(96, String(try #require(UnicodeScalar(NSF5FunctionKey))), [])
        )
        #expect(keys.lookups > lookups && keys.validations <= 2)
        #expect(
            MenuKeys.shortcuts(for: PanelProgram.key(8, "с", .command)).contains(Shortcut(.character("c"), .command))
        )
    }

    /// The bars rest after a slow check: an event alone asks for no new check, a change does.
    @Test
    internal func theBarsRestAfterASlowCheck() async throws {
        let app = await program.start()
        defer { app.stop() }
        let window = try #require(app.shell.mainWindow)
        await PanelWait.until { !window.isValidationPending }
        window.validateBars()
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window.window)
        #expect(!window.isValidationPending)
        window.scheduleValidation()
        #expect(window.isValidationPending)
    }
}
