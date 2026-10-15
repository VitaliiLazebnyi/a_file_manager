import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// Returning to a folder on a slow server through the real window: the listing cache ("show old,
/// refresh behind").
///
/// The memory file system plays the server: `listStartDelay` is how long it takes to answer,
/// `listRequests` how often it was asked.
@MainActor
@Suite(.serialized)
internal struct RememberedListingTests {
    private let program: PanelProgram

    /// The program's folders.
    internal init() throws {
        program = try PanelProgram(rightFile: "one.txt", contents: "old")
    }

    /// A share with a few entries, and a panel that has been in `/nas` and is back in `/` with the
    /// cursor on `nas`, so the folder is remembered.
    ///
    /// The server answers after `delay`.
    private func startWithARememberedFolder(delay: TimeInterval) async -> PanelProgram.Running {
        program.memory.addFile("/nas/a.txt", "a")
        program.memory.addFile("/nas/b.txt", "bb")
        program.memory.addFile("/nas/sub/in.txt", "12345")
        program.memory.listStartDelay = delay
        let app = await program.start()
        app.left.show(program.memory.url("/nas"))
        await program.settle(app)
        app.left.show(program.memory.url("/"), focus: "nas")
        await program.settle(app)
        return app
    }

    /// A remembered folder is shown at once, used while it is read afresh behind, and brought up
    /// to date where it changed, keeping the cursor, the marks and the sizes.
    @Test
    internal func aRememberedFolderIsShownAtOnceAndReadAfreshBehind() async {
        // The server is slow enough that everything below that has to happen before it
        // answers does, however busy the machine is.
        let app = await startWithARememberedFolder(delay: 3)
        defer { app.stop() }
        let memory = program.memory
        #expect(
            app.left.model.cursorItem?.name == "nas" && program.remembered(app, "/nas") == ["sub", "a.txt", "b.txt"]
        )
        // Meanwhile the folder changes on the server.
        memory.addFile("/nas/new.txt")
        memory.removeTree("/nas/b.txt")
        app.commands.perform(.open, .nothing)
        // The server has not answered, but the old listing is in the window, in the same turn.
        #expect(app.left.model.directory.path == "/nas" && app.names(app.left) == ["sub", "a.txt", "b.txt"])
        #expect(app.left.tableView.numberOfRows == 4 && app.left.model.backLocation?.path == "/")
        #expect(app.left.model.isRefreshing && !app.left.model.isComplete && !app.left.model.isOpening)
        #expect(app.left.isLoading && app.left.showsActivity)
        #expect(app.left.statusLineText == "Refreshing…   0 k / 0 k in 0 / 2 file(s), 0 / 1 dir(s)")
        // "Everything" has to wait for the fresh listing; what is named can be worked with.
        #expect(
            !app.commands.isEnabled(.selectAll) && !app.commands.isEnabled(.invertSelection)
                && !app.commands.isEnabled(.selectGroup)
        )
        app.cursor(app.left, on: "sub")
        #expect(app.commands.isEnabled(.copy) && app.commands.isEnabled(.delete) && app.commands.isEnabled(.goToParent))
        #expect(program.press(app, 49, []) && app.left.model.selection == ["sub"])  // Space: mark and measure
        #expect(await PanelWait.until { app.left.model.cursorItem?.computedSize == 5 })
        app.cursor(app.left, on: "a.txt")
        #expect(program.press(app, 49, []) && app.left.model.selection == ["sub", "a.txt"])
        // The fresh listing arrives: the list changes where the folder did, nothing else moves.
        await program.settle(app)
        #expect(app.names(app.left) == ["sub", "a.txt", "new.txt"] && app.left.tableView.numberOfRows == 4)
        #expect(app.left.model.cursorItem?.name == "a.txt" && app.left.model.selection == ["sub", "a.txt"])
        #expect(app.left.model.items.first?.computedSize == 5)
        #expect(
            app.left.model.isComplete && !app.left.model.isRefreshing && !app.left.isLoading && !app.left.showsActivity
        )
        #expect(app.left.statusLineText == "0 k / 0 k in 1 / 2 file(s), 1 / 1 dir(s)")
        #expect(app.commands.isEnabled(.selectAll) && app.commands.isEnabled(.invertSelection))
        // The server was asked once for the first visit and once for the refresh.
        #expect(memory.listRequests(for: "/nas") == 2 && program.remembered(app, "/nas") == ["sub", "a.txt", "new.txt"])
        #expect(app.left.model.backLocation?.path == "/" && app.left.model.forwardLocation == nil)
    }

    /// A quiet reload after a change by another program brings what is remembered up to date.
    @Test
    internal func readingAgainBringsWhatIsRememberedUpToDate() async {
        let app = await startWithARememberedFolder(delay: 0.3)
        defer { app.stop() }
        app.commands.perform(.open, .nothing)
        await program.settle(app)
        program.memory.addFile("/nas/later.txt")
        app.shell.panelCoordinator.reloadChangedPanels()
        // A folder that was read a moment ago is read again after a pause, not at once.
        await program.rest(app)
        #expect(app.names(app.left).contains("later.txt") && program.remembered(app, "/nas").contains("later.txt"))
    }

    /// A folder remembered in another order is sorted in the background, long before the server answers.
    @Test
    internal func aRememberedFolderInAnotherOrderIsSortedInTheBackground() async {
        let app = await startWithARememberedFolder(delay: 3)
        defer { app.stop() }
        app.left.model.setSort(ListOrder(key: .name, descending: true))
        app.commands.perform(.open, .nothing)
        #expect(await PanelWait.until(seconds: 2.5) { app.left.model.directory.path == "/nas" })
        #expect(app.names(app.left) == ["sub", "b.txt", "a.txt"] && app.left.model.isRefreshing)
        await program.settle(app)
        #expect(app.names(app.left) == ["sub", "b.txt", "a.txt"] && app.left.model.isComplete)
        let entry = app.kernel.listingCache.entry(for: program.memory.url("/nas"), showHidden: false)
        #expect(entry?.order == ListOrder(key: .name, descending: true))
    }

    /// A refresh that fails leaves the folder, tells the user and forgets what was remembered;
    /// the next attempt is an ordinary reading.
    @Test
    internal func aRefreshThatFailsLeavesTheFolderAndForgetsIt() async {
        let app = await startWithARememberedFolder(delay: 0.8)
        defer { app.stop() }
        program.memory.unreadable = ["/nas"]
        app.commands.perform(.open, .nothing)
        #expect(app.left.model.directory.path == "/nas" && app.left.model.isRefreshing)
        await program.settle(app)
        #expect(await PanelWait.until { !program.interaction.log.isEmpty })
        // As after any reading that failed: back where the panel was, and the user is told.
        #expect(app.left.model.directory.path == "/" && app.left.model.cursorItem?.name == "nas")
        #expect(app.left.model.isComplete && !app.left.model.isRefreshing && !app.left.showsActivity)
        #expect(
            app.left.model.forwardLocation == nil && program.interaction.log == ["inform: The folder cannot be read!"]
        )
        #expect(app.kernel.listingCache.age(of: program.memory.url("/nas"), showHidden: false) == nil)
        program.memory.unreadable = []
        app.commands.perform(.open, .nothing)
        #expect(app.left.model.directory.path == "/")
        await program.settle(app)
        #expect(app.left.model.directory.path == "/nas" && app.names(app.left) == ["sub", "a.txt", "b.txt"])
    }

    /// A folder that fails while another reading overtook the one that opened it goes back once
    /// and is reported once; nothing here depends on how long anything takes.
    @Test
    internal func aFolderThatFailsWhileAnotherReadingOvertookTheOpeningOneGoesBackOnceAndIsReportedOnce() async {
        let memory = program.memory
        memory.addFile("/nas/a.txt", "a")
        memory.stallsListings = true
        memory.stalledPaths = ["/nas"]
        memory.unreadable = ["/nas"]
        let app = await program.start()
        defer { app.stop() }
        let before = app.left.model.directory
        app.left.show(memory.url("/nas"))
        // Slow: the panel enters the folder, empty, and waits.
        #expect(await PanelWait.until { memory.stalledListings(of: "/nas") == 1 })
        #expect(await PanelWait.until { app.left.model.isOpening } && app.left.model.directory.path == "/nas")
        // Reading it again (a refresh) overtakes the first reading, which had the way back.
        app.commands.perform(.reread, .nothing)
        #expect(
            await PanelWait.until { memory.listRequests(for: "/nas") == 2 && memory.stalledListings(of: "/nas") == 1 }
        )
        #expect(app.left.isLoading)
        // Now the server answers: the folder cannot be read.
        memory.releaseStalls()
        #expect(await PanelWait.until { !app.left.isLoading })
        // The message comes from the run loop, a turn after the reading has ended.
        #expect(await PanelWait.until { !program.interaction.log.isEmpty })
        await PanelWait.pause(0.5)
        #expect(
            app.left.model.directory.isSameLocation(as: before) && app.left.model.isListed && app.left.model.isComplete
        )
        #expect(program.interaction.log.filter { $0 == "inform: The folder cannot be read!" }.count == 1)
        #expect(memory.listRequests(for: "/nas") == 2)
    }

    /// A reload that is turned away while the folder is read is made up for afterwards.
    @Test
    internal func aReloadThatIsTurnedAwayWhileTheFolderIsReadIsMadeUpForAfterwards() async {
        program.memory.addFile("/nas/a.txt", "a")
        let app = await program.start()
        defer { app.stop() }
        program.memory.listStartDelay = 1.5
        app.left.show(program.memory.url("/nas"))
        #expect(await PanelWait.until { program.memory.listRequests(for: "/nas") == 1 } && app.left.isLoading)
        // The folder changes while it is read; the watcher asks for a quiet reload.
        app.left.reload(focus: nil, quietly: true, completion: nil)
        #expect(app.left.hasPendingReread)
        await program.rest(app)
        #expect(program.memory.listRequests(for: "/nas") == 2 && !app.left.isLoading)
    }

    /// The completion of a reading that was overtaken hears that it came to nothing.
    @Test
    internal func theCompletionOfAReadingThatWasOvertakenHearsOfIt() async {
        program.memory.addFile("/nas/a.txt", "a")
        program.memory.addFile("/nas/sub/in.txt", "1")
        program.memory.listStartDelay = 0.3
        let app = await program.start()
        defer { app.stop() }
        var results: [String] = []
        app.left.show(program.memory.url("/nas"), focus: nil, history: .record) { results.append("first:\($0)") }
        app.left.show(program.memory.url("/nas/sub"), focus: nil, history: .record) { results.append("second:\($0)") }
        await program.settle(app)
        #expect(results == ["first:false", "second:true"] && app.left.model.directory.path == "/nas/sub")
    }

    /// A file that vanished meanwhile gives the usual error, and the job's reading puts the list right.
    @Test
    internal func aFileThatVanishedMeanwhileGivesTheUsualError() async {
        let app = await startWithARememberedFolder(delay: 0.8)
        defer { app.stop() }
        program.memory.removeTree("/nas/a.txt")
        app.commands.perform(.open, .nothing)
        app.cursor(app.left, on: "a.txt")
        #expect(app.left.model.cursorItem?.name == "a.txt")
        program.interaction.promptAnswers = [.accept]
        program.interaction.choiceAnswers = [0]
        app.commands.perform(.copy, .nothing)
        await program.settle(app)
        #expect(program.interaction.log.last == "choose: Error with a.txt / mem:/nas/a.txt does not exist any more!")
        #expect(!program.box.exists("B/a.txt"))
        #expect(app.names(app.left) == ["sub", "b.txt"] && app.left.model.isComplete && !app.left.model.isRefreshing)
    }

    /// An operation in a folder that is not shown makes it forgotten; entering it is an
    /// ordinary reading then.
    @Test
    internal func anOperationInAFolderThatIsNotShownMakesItForgotten() async {
        let app = await startWithARememberedFolder(delay: 0.3)
        defer { app.stop() }
        app.left.show(program.memory.url("/nas/sub"))
        await program.settle(app)
        app.commands.perform(.goToParent, .nothing)
        await program.settle(app)
        #expect(app.left.model.directory.path == "/nas" && program.remembered(app, "/nas/sub") == ["in.txt"])
        app.cursor(app.left, on: "a.txt")
        program.interaction.promptAnswers = [.text("/nas/sub/")]
        app.commands.perform(.copy, .nothing)
        await program.settle(app)
        #expect(program.memory.exists("/nas/sub/a.txt"))
        #expect(app.kernel.listingCache.age(of: program.memory.url("/nas/sub"), showHidden: false) == nil)
        let before = program.memory.listRequests(for: "/nas/sub")
        app.cursor(app.left, on: "sub")
        app.commands.perform(.open, .nothing)
        #expect(app.left.model.directory.path == "/nas")
        await program.settle(app)
        #expect(
            app.names(app.left) == ["a.txt", "in.txt"] && program.memory.listRequests(for: "/nas/sub") == before + 1
        )
    }

    /// Switched off, nothing is remembered.
    @Test
    internal func switchedOffNothingIsRemembered() async {
        program.settings.set(false, forKey: ListingCache.settingsKey)
        let app = await startWithARememberedFolder(delay: 0.3)
        defer { app.stop() }
        #expect(program.remembered(app, "/nas").isEmpty)
        app.commands.perform(.open, .nothing)
        #expect(app.left.model.directory.path == "/")
        await program.settle(app)
        #expect(app.left.model.directory.path == "/nas" && program.memory.listRequests(for: "/nas") == 2)
    }
}
