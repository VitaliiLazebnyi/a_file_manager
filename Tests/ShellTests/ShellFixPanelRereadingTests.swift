import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// Reading a folder again when an answer from the background or a timer meets a panel that has
/// moved on or is gone: changes noticed during a reading, a long reading again that is
/// overtaken, the timers of a panel that went away.
@MainActor
@Suite(.serialized)
internal struct ShellFixPanelRereadingTests {
    private let fixture = ShellFixPanel()
    private var panel: PanelViewController { fixture.panel }
    private var model: PanelModel { fixture.panel.model }

    /// A panel by itself in `/b` of `memory`, read once.
    private static func lonePanel(on memory: MemoryFileSystem) async -> PanelViewController {
        let kernel = Kernel(productName: "Test", settings: MemorySettings(), interaction: ScriptedInteraction())
        kernel.fileSystems.register(memory)
        // No job runs: the panel may read again whenever it wants to.
        kernel.commands.isBlocked = { false }
        let lone = PanelViewController(tabs: PanelTabs(PanelModel(directory: memory.url("/b"))), kernel: kernel)
        lone.view.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        lone.show(memory.url("/b"), focus: nil, history: .record, completion: nil)
        await PanelWait.until { !lone.isLoading }
        return lone
    }

    /// A change noticed during a reading is made up for once the reading is over, unless the
    /// reading began after it; asked meanwhile, the panel starts nothing.
    @Test
    internal func aChangeNoticedDuringAReadingIsMadeUpForAfterIt() async throws {
        await fixture.enterHalfOfC()
        let id = ObjectIdentifier(model)
        let reading = try #require(panel.loads[id])
        // Noticed before the reading began: the reading sees it.
        panel.reloadForChange(at: reading.started - 1)
        #expect(panel.dirty[id] == nil)
        // Noticed after: it is noted, and nothing starts while the reading is under way.
        panel.reloadForChange(at: ProcessInfo.processInfo.systemUptime)
        #expect(panel.dirty[id] == [model.directory.locationKey])
        panel.rereadIfDirty()
        #expect(panel.loads[id] === reading && fixture.script.listingsBegun == 1)
        fixture.script.open()
        // Once the reading is over, the folder is read once more.
        #expect(await PanelWait.until { fixture.script.listingsBegun == 2 && !panel.isLoading })
        #expect(panel.dirty[id] == nil && fixture.names == ["z1.txt", "z2.txt", "z3.txt"])
    }

    /// A long folder read again whose comparison with the list is under way when the panel goes
    /// elsewhere changes nothing.
    @Test
    internal func aLongReadingAgainThatIsOvertakenChangesNothing() async {
        for name in ShellFixPanel.names(PanelViewController.backgroundSortThreshold) {
            fixture.memory.addFile("/big/" + name)
        }
        await fixture.show("/big")
        fixture.memory.addFile("/big/new.txt")
        var told = false
        panel.reload(focus: nil, quietly: false) { told = true }
        // Right after the reading's answer has started the comparison in the background.
        ShellFixTurns.afterWork(inLane: "list", at: fixture.memory.url("/big")) { [panel, fixture] in
            panel.show(fixture.memory.url("/a"), focus: nil, history: .record, completion: nil)
        }
        #expect(await PanelWait.until { told && !panel.isLoading })
        await PanelWait.drainMainQueue()
        #expect(model.directory.path == "/a" && fixture.names == ["x.txt"])
    }

    /// A panel that went away before the timer of its next reading again fired: the timer does
    /// nothing.
    @Test
    internal func theRereadTimerOfAPanelThatWentAwayDoesNothing() async {
        let memory = MemoryFileSystem()
        memory.addFile("/b/y.txt")
        weak var gone: PanelViewController?
        do {
            let lone = await Self.lonePanel(on: memory)
            autoreleasepool {
                let id = ObjectIdentifier(lone.model)
                // Read a moment ago, at a cost that makes the pause before the next reading 2 s.
                lone.lastRead[id] = (ProcessInfo.processInfo.systemUptime, 1)
                lone.dirty[id] = [lone.model.directory.locationKey]
                lone.rereadIfDirty()
                #expect(lone.rereadTimers[id] != nil)
                gone = lone
            }
        }
        #expect(gone == nil)
        await ShellFixTurns.timer(after: 2)
        #expect(memory.listRequests(for: "/b") == 1)
    }

    /// Text typed into the quick filter of a panel that went away before the list followed it:
    /// the timer does nothing.
    @Test
    internal func theQuickFilterTimerOfAPanelThatWentAwayDoesNothing() async {
        let memory = MemoryFileSystem()
        memory.addFile("/b/y.txt")
        weak var gone: PanelViewController?
        var tab: PanelModel?
        do {
            let lone = await Self.lonePanel(on: memory)
            autoreleasepool {
                lone.showQuickFilter()
                lone.quickFilterEdited("y")
                #expect(lone.pendingQuickFilter != nil)
                (gone, tab) = (lone, lone.model)
            }
        }
        #expect(gone == nil)
        await ShellFixTurns.timer(after: PanelViewController.quickFilterDelay)
        #expect(tab?.filter == nil && tab?.items.map(\.name) == ["y.txt"])
    }

    /// A rename that was to start after a click of a panel that went away: the timer does nothing.
    @Test
    internal func theRenameTimerOfAPanelThatWentAwayDoesNothing() async {
        let memory = MemoryFileSystem()
        memory.addFile("/b/y.txt")
        weak var gone: PanelViewController?
        do {
            let lone = await Self.lonePanel(on: memory)
            autoreleasepool {
                lone.scheduleRename(row: 1, after: 0.05)
                #expect(lone.pendingRename != nil)
                gone = lone
            }
        }
        #expect(gone == nil)
        await ShellFixTurns.timer(after: 0.05)
        #expect(gone == nil)
    }
}
