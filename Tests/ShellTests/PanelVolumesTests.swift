import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The drive line and the volume figures of a panel by itself, with surroundings the test plays:
/// the volume list, the eject button, an overlay over the list, and new figures of a volume.
@MainActor
@Suite(.serialized)
internal struct PanelVolumesTests {
    private let kernel = Kernel(productName: "Test", settings: MemorySettings(), interaction: ScriptedInteraction())
    private let memory = MemoryFileSystem()
    private let host = PanelFakeHost()
    private let panel: PanelViewController

    /// A panel in `/a` of a memory file system, on screen-sized parts, with the test's host.
    internal init() {
        memory.addFile("/a/x.txt")
        memory.addFile("/b/y.txt")
        kernel.fileSystems.register(memory)
        panel = PanelViewController(tabs: PanelTabs(PanelModel(directory: memory.url("/a"))), kernel: kernel)
        panel.host = host
        panel.view.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        panel.view.layoutSubtreeIfNeeded()
    }

    /// Shows `/a` and waits until it is read.
    private func read() async {
        panel.show(memory.url("/a"), focus: nil, history: .keep, completion: nil)
        await PanelWait.until { !panel.isLoading }
    }

    /// The volume list shows the places, disks first, and keeps its title; the header menu is
    /// filled when it opens; other menus are not the panel's business.
    @Test
    internal func theVolumeListShowsThePlaces() throws {
        let menu = try #require(panel.volumeButton.menu)
        host.places = [
            Place(name: "Disk", url: URL(fileURLWithPath: "/"), kind: .internalDisk),
            Place(name: "Memory", url: memory.url("/"), kind: .externalDisk),
            Place(name: "Home", url: URL(fileURLWithPath: "/Users"), kind: .home),
            Place(name: "Projects", url: URL(fileURLWithPath: "/Users/Shared"), kind: .folder)
        ]
        panel.menuNeedsUpdate(menu)
        panel.menuNeedsUpdate(menu)
        #expect(menu.items.map(\.title) == ["mem", "Disk", "Memory", "", "Home", "Projects"])
        // Without the view commands (no plugin registered them) the header menu has nothing.
        panel.menuNeedsUpdate(panel.headerMenu)
        #expect(panel.headerMenu.items.isEmpty)
        let other = NSMenu()
        panel.menuNeedsUpdate(other)
        #expect(other.items.isEmpty)
        // While it is open, places that arrive go in.
        panel.menuWillOpen(menu)
        host.places.removeLast(2)
        panel.placesDidChange()
        #expect(menu.items.map(\.title) == ["mem", "Disk", "Memory"])
        panel.menuDidClose(menu)
        host.places = []
        panel.placesDidChange()
        #expect(menu.numberOfItems == 3)
    }

    /// A panel without surroundings lists no places.
    @Test
    internal func withoutSurroundingsTheVolumeListIsEmpty() throws {
        panel.host = nil
        let menu = try #require(panel.volumeButton.menu)
        panel.menuNeedsUpdate(menu)
        #expect(menu.items.map(\.title) == ["mem"])
    }

    /// An overlay covers the list while it is set, and goes when it is taken away.
    @Test
    internal func anOverlayCoversTheList() {
        let overlay = NSView()
        panel.overlay = overlay
        #expect(overlay.superview === panel.listArea)
        panel.overlay = nil
        #expect(overlay.superview == nil)
        let unseen = PanelViewController(tabs: PanelTabs(PanelModel(directory: memory.url("/a"))), kernel: kernel)
        unseen.overlay = overlay
        #expect(overlay.superview == nil && !unseen.isViewLoaded)
    }

    /// New figures of a volume are asked for by the tabs on it: once more when they come while a
    /// question is out; not for a tab that was closed; and only when it is that file system's.
    @Test
    internal func newVolumeFiguresAreAskedForByTheTabsOnTheVolume() async {
        await read()
        memory.isLocal = false
        let note = Notification(name: FileSystemRegistry.volumeInfoDidChange, object: memory, userInfo: nil)
        panel.volumeInfoChanged(note)
        panel.volumeInfoChanged(note)
        #expect(await PanelWait.until { panel.volumeAsking.isEmpty && panel.model.volume?.isLocal == false })
        let rooted = Notification(
            name: FileSystemRegistry.volumeInfoDidChange,
            object: memory,
            userInfo: [FileSystemRegistry.volumeRootKey: memory.url("/b")]
        )
        memory.isLocal = true
        panel.volumeInfoChanged(rooted)
        panel.volumeInfoChanged(Notification(name: FileSystemRegistry.volumeInfoDidChange, object: nil))
        await PanelWait.drainMainQueue()
        #expect(panel.model.volume?.isLocal == false && panel.volumeAsking.isEmpty)
        // A tab closed while its question is out takes nothing.
        let other = panel.tabs.insertTab(showing: memory.url("/a"), at: 1, activate: false)
        panel.volumeInfoChanged(note)
        _ = panel.tabs.closeTab(at: 1)
        await PanelWait.drainMainQueue()
        #expect(other.volume == nil)
    }

    /// A place chosen in the volume list is where the panel goes.
    @Test
    internal func aPlaceChosenInTheVolumeListIsWhereThePanelGoes() async throws {
        let program = try PanelProgram(rightFile: "fresh.txt", contents: "fresh")
        let app = await program.start(
            plugins: CorePlugins.make(pasteboard: program.scratch.pasteboard),
            fileSystems: []
        )
        defer { app.stop() }
        app.left.host = host
        host.places = [Place(name: "B", url: program.box.url("B"), kind: .folder)]
        let menu = try #require(app.left.volumeButton.menu)
        app.left.menuNeedsUpdate(menu)
        menu.performActionForItem(at: 1)
        await program.settle(app)
        #expect(app.left.model.directory.lastPathComponent == "B")
    }
}
