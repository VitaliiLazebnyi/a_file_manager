import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import AFMShell

/// Entering the folder under the cursor on a slow server through the real window: the folder is
/// read ahead while the cursor rests on it, and modestly.
///
/// The memory file system plays the server.
@MainActor
@Suite(.serialized)
internal struct PanelReadAheadProgramTests {
    private let program: PanelProgram

    /// The time the cursor has to rest, and a little more.
    private var rest: TimeInterval { ReadAhead.dwell + 0.3 }

    /// The program's folders.
    internal init() throws {
        program = try PanelProgram(rightFile: "one.txt", contents: "old")
    }

    /// A share (not a local volume) with two folders and a file, shown in the left panel of a
    /// window that counts as active.
    ///
    /// The server answers after `delay`.
    private func startOnAShare(delay: TimeInterval) async -> PanelProgram.Running {
        program.memory.isLocal = false
        for index in 0..<3 {
            program.memory.addFile("/nas/one/file\(index).txt")
        }
        program.memory.addFile("/nas/two/y.txt")
        program.memory.addFile("/nas/file.txt")
        program.memory.listStartDelay = delay
        let app = await program.start()
        app.shell.panelCoordinator.isWindowActive = { true }
        app.left.show(program.memory.url("/nas"))
        await program.settle(app)
        return app
    }

    /// The folder under the cursor is read once the cursor has rested there; Enter finds it, and
    /// what was read a moment ago is not read ahead again.
    @Test
    internal func theFolderUnderTheCursorIsReadAheadAfterAMoment() async {
        let app = await startOnAShare(delay: 0)
        defer { app.stop() }
        let (memory, cache) = (program.memory, app.kernel.listingCache)
        // On [..] and on a file nothing is read.
        #expect(app.left.model.cursorIsOnParentRow)
        await PanelWait.pause(rest)
        app.cursor(app.left, on: "file.txt")
        await PanelWait.pause(rest)
        // Only the folder shown was read (a change noticed while it was read may read it again).
        #expect(Set(memory.listRequests) == ["/nas"])
        // On a folder: not at once, but once the cursor has rested there.
        app.cursor(app.left, on: "one")
        await PanelWait.pause(ReadAhead.dwell / 2)
        #expect(memory.listRequests(for: "/nas/one") == 0)
        #expect(await PanelWait.until { cache.age(of: memory.url("/nas/one"), showHidden: false) != nil })
        #expect(memory.listRequests(for: "/nas/one") == 1)
        // Enter finds it there.
        app.commands.perform(.open, .nothing)
        #expect(app.left.model.directory.path == "/nas/one" && app.names(app.left).count == 3)
        await program.settle(app)
        app.commands.perform(.goToParent, .nothing)
        await program.settle(app)
        // What was read a moment ago is not read ahead again.
        let requests = memory.listRequests(for: "/nas/one")
        #expect(app.left.model.cursorItem?.name == "one")
        app.cursor(app.left, on: "file.txt")
        app.cursor(app.left, on: "one")
        await PanelWait.pause(rest)
        #expect(memory.listRequests(for: "/nas/one") == requests && memory.listRequests(for: "/nas/two") == 0)
    }

    /// Nothing is read ahead in a window that is not the active one, nor on a local volume.
    @Test
    internal func nothingIsReadAheadOnALocalVolumeOrInAnInactiveWindow() async {
        let app = await startOnAShare(delay: 0)
        defer { app.stop() }
        app.shell.panelCoordinator.isWindowActive = { false }
        app.cursor(app.left, on: "one")
        await PanelWait.pause(rest)
        #expect(program.memory.listRequests(for: "/nas/one") == 0)
        // The same folders on a local volume.
        app.shell.panelCoordinator.isWindowActive = { true }
        program.memory.isLocal = true
        app.commands.perform(.reread, .nothing)
        await program.settle(app)
        #expect(app.left.model.volume?.isLocal == true)
        app.cursor(app.left, on: "two")
        app.cursor(app.left, on: "one")
        await PanelWait.pause(rest)
        #expect(program.memory.listRequests(for: "/nas/one") == 0 && program.memory.listRequests(for: "/nas/two") == 0)
        #expect(app.shell.panelCoordinator.readAhead.reading == nil)
    }

    /// Reading ahead can be switched off.
    @Test
    internal func readingAheadCanBeSwitchedOff() async {
        program.settings.set(false, forKey: ReadAhead.settingsKey)
        let app = await startOnAShare(delay: 0)
        defer { app.stop() }
        app.cursor(app.left, on: "one")
        await PanelWait.pause(rest)
        #expect(program.memory.listRequests(for: "/nas/one") == 0)
    }

    /// Moving the cursor gives up a reading ahead, and the next waits until it has come back;
    /// Enter while a folder is read ahead waits for that reading instead of asking again.
    @Test
    internal func movingTheCursorCancelsAReadAheadAndEnterJoinsOne() async {
        let app = await startOnAShare(delay: 2.5)
        defer { app.stop() }
        let (memory, cache) = (program.memory, app.kernel.listingCache)
        app.cursor(app.left, on: "one")
        #expect(await PanelWait.until { memory.listRequests(for: "/nas/one") == 1 })
        #expect(app.shell.panelCoordinator.readAhead.reading != nil)
        // The cursor moves on while the server is still busy with /nas/one: that reading is
        // given up, and /nas/two has to wait until it has come back.
        app.cursor(app.left, on: "two")
        #expect(await PanelWait.until { memory.listRequests(for: "/nas/two") == 1 })
        #expect(cache.age(of: memory.url("/nas/one"), showHidden: false) == nil)
        // Enter while /nas/two is on its way: the panel waits for that reading.
        app.commands.perform(.open, .nothing)
        #expect(app.left.model.directory.path == "/nas" && app.left.isLoading)
        // The folder is entered while it is still read (on a machine too busy to see that, the
        // reading may have come back by then).
        #expect(await PanelWait.until { app.left.model.directory.path == "/nas/two" })
        if app.left.model.isOpening {
            #expect(app.left.statusLineText == "Reading mem:/nas/two…")
        }
        await program.settle(app)
        #expect(app.names(app.left) == ["y.txt"] && app.left.model.isComplete && !app.left.model.isRefreshing)
        #expect(app.left.model.backLocation?.path == "/nas")
        // The server was asked for it once, and never for two folders at the same time.
        await PanelWait.pause(0.3)
        #expect(memory.listRequests(for: "/nas/two") == 1 && memory.mostListingsAtOnce == 1)
        #expect(memory.listRequests == ["/nas", "/nas/one", "/nas/two"])
    }

    /// A folder that could not be read ahead is tried once, quietly, and then left alone.
    @Test
    internal func aFolderThatCouldNotBeReadAheadIsLeftAlone() async {
        program.memory.addDirectory("/nas/locked")
        program.memory.unreadable = ["/nas/locked"]
        let app = await startOnAShare(delay: 0)
        defer { app.stop() }
        app.cursor(app.left, on: "locked")
        #expect(
            await PanelWait.until {
                program.memory.listRequests(for: "/nas/locked") == 1
                    && app.shell.panelCoordinator.readAhead.reading == nil
            }
        )
        app.cursor(app.left, on: "file.txt")
        app.cursor(app.left, on: "locked")
        await PanelWait.pause(rest)
        #expect(program.memory.listRequests(for: "/nas/locked") == 1 && program.interaction.log.isEmpty)
    }

    /// Nothing is read ahead while a job runs; when it has ended, the folder under the cursor
    /// gets its turn; a job that starts stops a reading ahead.
    @Test
    internal func nothingIsReadAheadWhileAJobRunsAndAJobThatStartsStopsIt() async {
        let app = await startOnAShare(delay: 0.8)
        defer { app.stop() }
        let gate = DispatchSemaphore(value: 0)
        app.kernel.jobs.run(
            title: "Busy",
            work: { _ in gate.wait() },
            completion: { _ in
                // Only that a job runs counts here.
            }
        )
        app.cursor(app.left, on: "one")
        await PanelWait.pause(rest)
        #expect(app.kernel.jobs.isBusy && program.memory.listRequests(for: "/nas/one") == 0)
        gate.signal()
        #expect(await PanelWait.until { program.memory.listRequests(for: "/nas/one") == 1 })
        #expect(app.shell.panelCoordinator.readAhead.reading != nil)
        // A job that starts while the folder is read ahead: the answer is not used.
        app.kernel.jobs.run(
            title: "Busy",
            work: { _ in gate.wait() },
            completion: { _ in
                // Only that a job runs counts here.
            }
        )
        #expect(await PanelWait.until { app.shell.panelCoordinator.readAhead.reading == nil } && app.kernel.jobs.isBusy)
        #expect(app.kernel.listingCache.age(of: program.memory.url("/nas/one"), showHidden: false) == nil)
        gate.signal()
        await program.settle(app)
    }
}
