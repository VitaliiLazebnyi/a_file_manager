import AFMContracts
import AFMKernel
import AppKit
import StandardPlugins
import TestSupport
import Testing

@testable import AFMShell

/// A long folder that is remembered is entered through the model's prepared form, in the real window.
///
/// The model's prepared form is `PanelModel.prepare(_:show:…)`, not one call on the main thread
/// (review round 2, shell-p2 "Not done"). The memory file system plays the server and answers
/// when the test lets it, so nothing here depends on how long anything takes.
@MainActor
@Suite(.serialized)
internal struct AppRememberedFolderTests {
    /// The program's folders and stand-ins.
    private let fixture: AppFixture

    /// The file system in memory that plays the server.
    private var memory: MemoryFileSystem { fixture.memory }

    /// A sandbox with the program's files.
    internal init() throws {
        fixture = try AppFixture(files: AppFixture.programFiles)
    }

    /// How many entries the listing cache of `app` remembers for `path` on the memory file
    /// system; nil when it remembers nothing.
    private func rememberedCount(_ app: AppRun, _ path: String) -> Int? {
        app.kernel.listingCache.entry(for: memory.url(path), showHidden: false)?.listing.items.count
    }

    /// A long folder on a share, and a panel that has been in it and is back in `/` with
    /// the cursor on it, so that it is remembered.
    private func startWithALongRememberedFolder(_ count: Int) async -> AppRun {
        for number in 0..<count {
            memory.addFile("/long/f\(number).txt", "x")
        }
        memory.listStartDelay = 0.8
        let app = await fixture.startProgram()
        app.left.show(memory.url("/long"))
        await AppWait.until { app.left.model.isComplete && app.left.model.directory.path == "/long" }
        await app.settle()
        app.left.show(memory.url("/"), focus: "long")
        await AppWait.until { app.left.model.isComplete && app.left.model.directory.path == "/" }
        await app.settle()
        memory.listStartDelay = 0
        return app
    }

    /// The remembered listing is shown at once, without the server; the server's answer brings it up to date.
    @Test
    internal func aLongRememberedFolderIsEnteredFromTheBackgroundAndBroughtUpToDate() async {
        let count = PanelViewController.backgroundSortThreshold + 500
        let app = await startWithALongRememberedFolder(count)
        defer { app.stop() }
        #expect(rememberedCount(app, "/long") == count)
        // From now on the server does not answer until the test lets it; meanwhile the folder changes there.
        memory.stallsListings = true
        memory.stalledPaths = ["/long"]
        memory.addFile("/long/new.txt", "new")
        app.commands.perform(.open)
        // The old listing arrives without the server having said a word.
        let shown = await AppWait.until { app.left.model.directory.path == "/long" && app.left.model.isListed }
        #expect(shown && app.left.model.items.count == count && app.left.tableView.numberOfRows == count + 1)
        #expect(app.left.model.isRefreshing && !app.left.model.isComplete && app.left.model.backLocation?.path == "/")
        #expect(memory.stalledListings(of: "/long") == 1 || !app.left.model.isComplete)
        // The cursor can be used in it.
        app.cursor(app.left, on: "f77.txt")
        #expect(app.left.model.cursorItem?.name == "f77.txt")
        // Now the server answers: the list is brought up to date, the cursor stays on its file.
        let asked = await AppWait.until { memory.stalledListings(of: "/long") == 1 }
        #expect(asked)
        memory.releaseStalls()
        let fresh = await AppWait.until { app.left.model.isComplete && !app.left.isLoading }
        #expect(fresh && app.left.model.items.count == count + 1 && app.left.model.row(ofName: "new.txt") != nil)
        #expect(app.left.model.cursorItem?.name == "f77.txt" && !app.left.model.isRefreshing)
    }

    /// When the server cannot read the folder after all, the panel goes back and forgets the listing.
    @Test
    internal func aLongRememberedFolderWhoseServerFailsLeavesThePanelWhereItWasWithItsQuickFilter() async {
        let count = PanelViewController.backgroundSortThreshold + 500
        let app = await startWithALongRememberedFolder(count)
        defer { app.stop() }
        memory.stallsListings = true
        memory.stalledPaths = ["/long"]
        memory.unreadable = ["/long"]
        app.commands.perform(.open)
        // Shown from memory, or still on its way into the list: either way the reading is under way.
        let asked = await AppWait.until { memory.stalledListings(of: "/long") == 1 }
        #expect(asked)
        memory.releaseStalls()
        let back = await AppWait.until {
            !app.left.isLoading && app.left.model.directory.path == "/" && app.left.model.isComplete
        }
        #expect(back && app.left.model.cursorItem?.name == "long")
        // What could not be read is not remembered any more.
        #expect(rememberedCount(app, "/long") == nil)
    }
}
