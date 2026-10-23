import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The folder tabs of a panel: what goes with a tab that is closed, tabs changed before the panel
/// is on screen, a tab moved while a job runs, and a tab restored at the top of its file system.
@MainActor
@Suite(.serialized)
internal struct PanelTabsTests {
    private let program: PanelProgram

    /// The program's folders: `A` with `docs`, `one.txt`, `two.txt`; `B` with `fresh.txt`.
    internal init() throws {
        program = try PanelProgram(rightFile: "fresh.txt", contents: "fresh")
    }

    /// Starts the program with the plugins a file manager cannot do without.
    private func start() async -> PanelProgram.Running {
        await program.start(plugins: CorePlugins.make(pasteboard: program.scratch.pasteboard), fileSystems: [])
    }

    /// A closed tab takes with it what was under way for it: whoever waited for its reading hears
    /// of it, its timers stop, its calculations, filterings and questions are cancelled, and a
    /// change it had still to read is forgotten.
    @Test
    internal func whatBelongsToAClosedTabGoesWithIt() async {
        let app = await start()
        defer { app.stop() }
        let panel = app.left
        let closing = panel.model
        _ = panel.tabs.insertTab(showing: program.box.url("B"), at: 1, activate: true)
        await program.settle(app)
        let id = ObjectIdentifier(closing)
        var heard: [String] = []
        let (size, volume) = (CancellationFlag(), CancellationFlag())
        panel.waitingCompletions[id] = [{ heard.append("told") }]
        panel.rereadTimers[id] = { heard.append("timer stopped") }
        panel.sizeCalculations[id] = size
        panel.filterJobs[id] = 7
        panel.volumeAsking[id] = volume
        panel.dirty[id] = [closing.directory.locationKey]
        #expect(panel.tabs.closeTab(at: 0))
        #expect(heard.sorted() == ["timer stopped", "told"] && size.isCancelled && volume.isCancelled)
        #expect(panel.sizeCalculations[id] == nil && panel.filterJobs[id] == nil && panel.volumeAsking[id] == nil)
        #expect(panel.rereadTimers[id] == nil && panel.waitingCompletions[id] == nil && panel.dirty[id] == nil)
    }

    /// Tabs and lists that change before the panel is on screen are drawn when it is.
    @Test
    internal func changesBeforeThePanelIsOnScreenWaitForIt() {
        let kernel = Kernel(productName: "Test", settings: MemorySettings(), interaction: ScriptedInteraction())
        let memory = MemoryFileSystem()
        memory.addFile("/a/x.txt")
        kernel.fileSystems.register(memory)
        let panel = PanelViewController(tabs: PanelTabs(PanelModel(directory: memory.url("/a"))), kernel: kernel)
        _ = panel.tabs.insertTab(showing: memory.url("/"), at: 1, activate: false)
        panel.model.moveCursor(to: 0)
        #expect(!panel.isViewLoaded && panel.tabs.tabs.count == 2 && panel.loads.isEmpty)
    }

    /// While a job runs a tab is not moved, and the user hears that it was turned away.
    @Test
    internal func aTabIsNotMovedWhileAJobRuns() async {
        let app = await start()
        defer { app.stop() }
        _ = app.left.tabs.insertTab(showing: program.box.url("B"), at: 1, activate: false)
        let gate = DispatchSemaphore(value: 0)
        app.kernel.jobs.run(
            title: "Busy",
            work: { _ in gate.wait() },
            completion: { _ in
                // Only that a job runs counts here.
            }
        )
        defer { gate.signal() }
        app.left.moveTab(from: 0, to: 1)
        #expect(app.left.tabs.tabs.first?.directory.path == program.box.url("A").path && app.rejections == 1)
    }

    /// A tab restored at the top of its file system is read when it is first shown; there is
    /// nothing above it to fall back on.
    @Test
    internal func aTabAtTheTopOfItsFileSystemIsReadWhenShown() async {
        let app = await start()
        defer { app.stop() }
        let top = URL(fileURLWithPath: "/", isDirectory: true)
        _ = app.left.tabs.insertTab(showing: top, at: 1, activate: false)
        app.left.tabs.activate(1)
        await program.settle(app)
        #expect(app.left.model.directory.path == "/" && app.left.model.isListed)
    }
}
