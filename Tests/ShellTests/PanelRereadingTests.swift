import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import AFMShell

/// Reading a panel's folder again through the real program (review 2, S009, S022, S025 – S029,
/// S063, S064): a folder merely read again disturbs nobody, many reports are one reading, and a
/// reading that was put off is made up for.
@MainActor
@Suite(.serialized)
internal struct PanelRereadingTests {
    private let program: PanelProgram

    /// The program's folders.
    internal init() throws {
        program = try PanelProgram(rightFile: "one.txt", contents: "old")
    }

    /// A folder that is merely read again is not announced as a new place; going somewhere is,
    /// once, also when a second reading of the same folder overtook the first.
    @Test
    internal func aFolderThatIsMerelyReadAgainIsNotAnnouncedAsANewPlace() async throws {
        let app = await program.start()
        defer { app.stop() }
        await program.rest(app)
        var places = 0
        let subscription = app.kernel.panelEvents.subscribe { event, _ in
            if event == .locationChanged {
                places += 1
            }
        }
        defer { _ = subscription }
        // The program is activated, another program touches the folder, a plugin asks for a refresh.
        app.shell.panelCoordinator.reloadChangedPanels()
        await program.rest(app)
        try program.box.file("A/extra.txt")
        var read = false
        app.left.reload(focus: nil, quietly: false) { read = true }
        await PanelWait.until { read }
        await program.rest(app)
        #expect(app.names(app.left).contains("extra.txt") && places == 0)
        app.left.show(program.box.url("A/docs"))
        await program.settle(app)
        #expect(places == 1 && app.left.model.directory.lastPathComponent == "docs")
        // The folder does not answer until the test lets it: it is still being opened when it is
        // shown again, however busy the machine is.
        program.memory.addFile("/slow/a.txt")
        program.memory.stalledPaths = ["/slow"]
        program.memory.stallsListings = true
        app.left.show(program.memory.url("/slow"))
        #expect(await PanelWait.until { app.left.model.isOpening })
        app.left.show(program.memory.url("/slow"))
        #expect(app.left.model.isOpening)
        program.memory.stallsListings = false
        program.memory.releaseStalls()
        await program.settle(app)
        #expect(app.left.model.directory.path == "/slow" && places == 2)
    }

    /// Two hundred reported changes are one reading after a pause, or one at once and one that
    /// makes up for the rest.
    @Test
    internal func manyReportedChangesAreOneReadingAfterAPause() async {
        program.memory.addFile("/busy/a.txt")
        let app = await program.start()
        defer { app.stop() }
        app.left.show(program.memory.url("/busy"))
        await program.rest(app)
        let before = program.memory.listRequests(for: "/busy")
        for _ in 0..<200 {
            app.shell.panelCoordinator.reloadChangedPanels(showing: [program.memory.url("/busy")])
        }
        await program.rest(app)
        let readings = program.memory.listRequests(for: "/busy") - before
        #expect(readings >= 1 && readings <= 2)
    }

    /// Whoever waits for a reload that was put off is told when the folder has been read.
    @Test
    internal func whoWaitsForAReloadThatWasPutOffIsToldWhenTheFolderHasBeenRead() async {
        program.memory.addFile("/slow/a.txt")
        let app = await program.start()
        defer { app.stop() }
        app.left.show(program.memory.url("/slow"))
        await program.rest(app)
        program.memory.listStartDelay = 0.2
        let before = program.memory.listRequests(for: "/slow")
        var told: [String] = []
        app.left.reload(focus: nil, quietly: false) { told.append("loud") }
        app.left.reload(focus: nil, quietly: true) {
            told.append("quiet after \(program.memory.listRequests(for: "/slow") - before)")
        }
        #expect(told.isEmpty)
        #expect(await PanelWait.until { told.count == 2 })
        // The quiet one was turned away while the folder was read, and made up for afterwards.
        #expect(told == ["loud", "quiet after 2"])
    }

    /// Reading the folder again does not throw over a navigation that is under way.
    @Test
    internal func readingTheFolderAgainDoesNotThrowOverANavigationThatIsUnderWay() async {
        program.memory.addFile("/far/x.txt")
        program.memory.listStartDelay = 0.2
        let app = await program.start()
        defer { app.stop() }
        var shown: [Bool] = []
        var reloaded = false
        app.left.show(program.memory.url("/far"), focus: nil, history: .record) { shown.append($0) }
        app.left.reload(focus: nil, quietly: false) { reloaded = true }
        #expect(await PanelWait.until { !shown.isEmpty && reloaded })
        #expect(shown == [true] && app.left.model.directory.path == "/far" && app.names(app.left) == ["x.txt"])
        #expect(!app.left.hasPendingReread)
    }

    /// A folder that was entered empty and left again is not in the history.
    @Test
    internal func aFolderThatWasEnteredEmptyAndLeftAgainIsNotInTheHistory() async {
        program.memory.addFile("/p1/a.txt")
        program.memory.addFile("/p2/b.txt")
        program.memory.stallsListings = true
        let app = await program.start()
        defer { app.stop() }
        app.left.show(program.memory.url("/p1"))
        #expect(await PanelWait.until { app.left.model.isOpening && app.left.model.directory.path == "/p1" })
        app.left.show(program.memory.url("/p2"))
        #expect(await PanelWait.until { app.left.model.isOpening && app.left.model.directory.path == "/p2" })
        program.memory.releaseStalls()
        await program.settle(app)
        #expect(app.names(app.left) == ["b.txt"])
        // Back leads to where the panel really was, not to the folder that never showed anything.
        #expect(app.left.model.backLocation?.lastPathComponent == "A" && app.left.model.forwardLocation == nil)
    }

    /// The completion of a reading whose tab is closed hears that it came to nothing.
    @Test
    internal func theCompletionOfAReadingWhoseTabIsClosedHearsOfIt() async {
        program.memory.addFile("/stuck/a.txt")
        let app = await program.start()
        defer {
            program.memory.releaseStalls()
            app.stop()
        }
        app.commands.perform(.newTab, .nothing)
        await program.settle(app)
        program.memory.stallsListings = true
        var result: [Bool] = []
        app.left.show(program.memory.url("/stuck"), focus: nil, history: .record) { result.append($0) }
        #expect(app.left.isLoading && app.left.tabs.tabs.count == 2)
        app.commands.perform(.closeTab, .nothing)
        #expect(await PanelWait.until { !result.isEmpty })
        #expect(result == [false] && app.left.tabs.tabs.count == 1)
    }

    /// A panel that was shut down reads nothing more, and whoever asks hears so.
    @Test
    internal func aPanelThatWasShutDownReadsNothing() async {
        let app = await program.start()
        defer { app.stop() }
        app.left.cancelLoading()
        var heard: [String] = []
        app.left.show(program.box.url("B"), focus: nil, history: .record) { heard.append("show \($0)") }
        app.left.reload(focus: nil, quietly: false) { heard.append("reload") }
        #expect(await PanelWait.until { heard.count == 2 })
        #expect(Set(heard) == ["show false", "reload"] && app.left.model.directory.lastPathComponent == "A")
    }

    /// A quick filter comes back with the folder when the next folder, entered empty because it
    /// answered late, cannot be read.
    @Test
    internal func aQuickFilterComesBackWithTheFolderWhenTheNextOneCannotBeRead() async {
        let memory = program.memory
        memory.addFile("/here/alpha.txt")
        memory.addFile("/here/beta.txt")
        memory.addDirectory("/here/locked")
        let app = await program.start()
        defer { app.stop() }
        app.left.show(memory.url("/here"))
        await program.settle(app)
        app.left.showQuickFilter()
        app.left.quickFilterTyped("a")
        #expect(app.names(app.left) == ["alpha.txt", "beta.txt"])
        app.left.quickFilterTyped("al")
        #expect(app.names(app.left) == ["alpha.txt"] && app.left.quickFilterText == "al")
        // The folder that is entered answers when the test lets it, and with an error: the panel
        // has entered it empty by then (which takes the quick filter away) and goes back.
        memory.unreadable = ["/here/locked"]
        memory.stallsListings = true
        memory.stalledPaths = ["/here/locked"]
        app.left.show(memory.url("/here/locked"))
        #expect(await PanelWait.until { app.left.model.isOpening })
        #expect(app.left.quickFilterText == nil)
        memory.releaseStalls()
        #expect(await PanelWait.until { !app.left.isLoading })
        #expect(app.left.model.directory.path == "/here" && app.names(app.left) == ["alpha.txt"])
        #expect(app.left.quickFilterText == "al" && app.left.model.filter?.title == "⏷ al")
        // Esc still takes it away.
        app.left.removeQuickFilter()
        #expect(app.names(app.left) == ["locked", "alpha.txt", "beta.txt"] && app.left.model.filter == nil)
    }
}
