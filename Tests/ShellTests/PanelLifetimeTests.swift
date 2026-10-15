import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// What a panel keeps alive: once nobody holds it, the panel goes with its views and its stores,
/// also after it has read a folder.
@MainActor
@Suite
internal struct PanelLifetimeTests {
    /// The parts of a panel that should go with it.
    private struct Parts {
        weak var panel: PanelViewController?
        weak var tabBar: TabBarView?
        weak var pathBar: PathBarView?
        weak var quickFilterBar: QuickFilterBar?
        weak var table: FileTableView?
        weak var grid: FileGridView?
    }

    /// A panel that was shown, read a folder and was shut down goes when it is let go of.
    @Test
    internal func aPanelThatIsLetGoOfGoesWithItsViews() async {
        let kernel = Kernel(productName: "Test", settings: MemorySettings(), interaction: ScriptedInteraction())
        let memory = MemoryFileSystem()
        memory.addFile("/a/x.txt")
        memory.addFile("/b/y.txt")
        kernel.fileSystems.register(memory)
        var parts = Parts()
        do {
            let panel = PanelViewController(tabs: PanelTabs(PanelModel(directory: memory.url("/a"))), kernel: kernel)
            panel.view.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
            panel.view.layoutSubtreeIfNeeded()
            panel.tabs.insertTab(showing: memory.url("/b"), at: 1, activate: false)
            panel.show(memory.url("/a"), focus: "x.txt", history: .keep, completion: nil)
            #expect(await PanelWait.until { !panel.isLoading })
            #expect(panel.model.items.map(\.name) == ["x.txt"])
            panel.cancelLoading()
            parts = Parts(
                panel: panel,
                tabBar: panel.tabBar,
                pathBar: panel.pathBar,
                quickFilterBar: panel.quickFilterBar,
                table: panel.tableView,
                grid: panel.gridView
            )
        }
        await PanelWait.drainMainQueue()
        #expect(await PanelWait.until { parts.panel == nil })
        #expect(parts.tabBar == nil && parts.pathBar == nil && parts.quickFilterBar == nil)
        #expect(parts.table == nil && parts.grid == nil)
    }
}
