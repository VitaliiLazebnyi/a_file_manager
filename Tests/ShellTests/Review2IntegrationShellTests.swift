import AFMContracts
import AFMKernel
import AppKit
import StandardPlugins
import TestSupport
import Testing

@testable import AFMShell

/// Review round 2, integration: a long folder that is remembered is entered through the
/// model's prepared form (`PanelModel.prepare(_:show:…)`), not in one call on the main
/// thread (shell-p2 "Not done"), through the real window. The memory file system plays the
/// server and answers when the test lets it, so nothing here depends on how long anything takes.
extension Application {
    /// A long folder on a share, and a panel that has been in it and is back in `/` with
    /// the cursor on it, so that it is remembered.
    private func startWithALongRememberedFolder(_ count: Int) async -> Running {
        for number in 0..<count { memory.addFile("/long/f\(number).txt", "x") }
        memory.listStartDelay = 0.8
        let app = await start()
        app.left.show(memory.url("/long"))
        await wait(upTo: 600) { app.left.model.isComplete && app.left.model.directory.path == "/long" }
        await settle(app)
        app.left.show(memory.url("/"), focus: "long")
        await wait(upTo: 600) { app.left.model.isComplete && app.left.model.directory.path == "/" }
        await settle(app)
        memory.listStartDelay = 0
        return app
    }

    @Test func aLongRememberedFolderIsEnteredFromTheBackgroundAndBroughtUpToDate() async {
        let count = PanelViewController.backgroundSortThreshold + 500
        let app = await startWithALongRememberedFolder(count)
        defer { app.stop() }
        #expect(remembered(app, "/long")?.count == count)
        // From now on the server does not answer until the test lets it; meanwhile the folder changes there.
        memory.stallsListings = true
        memory.stalledPaths = ["/long"]
        memory.addFile("/long/new.txt", "new")
        app.commands.perform(.open)
        // The old listing arrives without the server having said a word.
        let shown = await wait(upTo: 600) { app.left.model.directory.path == "/long" && app.left.model.isListed }
        #expect(shown && app.left.model.items.count == count && app.left.tableView.numberOfRows == count + 1)
        #expect(app.left.model.isRefreshing && !app.left.model.isComplete && app.left.model.backLocation?.path == "/")
        #expect(memory.stalledListings(of: "/long") == 1 || !app.left.model.isComplete)
        // The cursor can be used in it.
        app.cursor(app.left, on: "f77.txt")
        #expect(app.left.model.cursorItem?.name == "f77.txt")
        // Now the server answers: the list is brought up to date, the cursor stays on its file.
        let asked = await wait(upTo: 600) { memory.stalledListings(of: "/long") == 1 }
        #expect(asked)
        memory.releaseStalls()
        let fresh = await wait(upTo: 600) { app.left.model.isComplete && !app.left.isLoading }
        #expect(fresh && app.left.model.items.count == count + 1 && app.left.model.row(ofName: "new.txt") != nil)
        #expect(app.left.model.cursorItem?.name == "f77.txt" && !app.left.model.isRefreshing)
    }

    @Test func aLongRememberedFolderWhoseServerFailsLeavesThePanelWhereItWasWithItsQuickFilter() async {
        let count = PanelViewController.backgroundSortThreshold + 500
        let app = await startWithALongRememberedFolder(count)
        defer { app.stop() }
        memory.stallsListings = true
        memory.stalledPaths = ["/long"]
        memory.unreadable = ["/long"]
        app.commands.perform(.open)
        // Shown from memory, or still on its way into the list: either way the reading is under way.
        let asked = await wait(upTo: 600) { memory.stalledListings(of: "/long") == 1 }
        #expect(asked)
        memory.releaseStalls()
        let back = await wait(upTo: 600) {
            !app.left.isLoading && app.left.model.directory.path == "/" && app.left.model.isComplete
        }
        #expect(back && app.left.model.cursorItem?.name == "long")
        // What could not be read is not remembered any more.
        #expect(remembered(app, "/long") == nil)
    }
}
