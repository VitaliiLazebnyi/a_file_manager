import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// How the panels start, and the places the coordinator keeps for them.
@MainActor
@Suite(.serialized)
internal struct WindowCovCoordinatorTests {
    /// A file system on a "server" whose places the test sets.
    private let watched = PanelWatchedFileSystem()

    /// A folder on the file system.
    internal init() {
        _ = NSApplication.shared
        watched.inner.addFile("/a/one.txt")
    }

    /// A tab that would connect to a server at the start gives way to another tab, or to a new
    /// one at home when every tab would.
    @Test
    internal func tabsThatWouldConnectAtTheStartGiveWay() {
        let kernel = Kernel(productName: "Test", settings: MemorySettings(), interaction: ScriptedInteraction())
        kernel.fileSystems.register(watched)
        watched.connectsToServer = true
        let home = URL(fileURLWithPath: "/home-of-the-test")
        let server = watched.url("/a")
        let mixed = PanelTabs(PanelModel(directory: server))
        mixed.insertTab(showing: URL(fileURLWithPath: "/elsewhere"), at: 1, activate: false)
        PanelCoordinator.keepFromConnectingAtStart(mixed, home: home, fileSystems: kernel.fileSystems)
        #expect(mixed.active.directory.path == "/elsewhere" && mixed.tabs.count == 2)
        let servers = PanelTabs(PanelModel(directory: server))
        PanelCoordinator.keepFromConnectingAtStart(servers, home: home, fileSystems: kernel.fileSystems)
        #expect(servers.tabs.count == 2 && servers.active.directory == home)
        #expect(servers.tabs.last?.directory == server)
    }

    /// The places that come after the panels have gone reach nobody; the drive of a folder on a
    /// drive that can be ejected is found.
    @Test
    internal func placesAfterThePanelsWentReachNobody() async {
        let kernel = Kernel(productName: "Test", settings: MemorySettings(), interaction: ScriptedInteraction())
        kernel.fileSystems.register(watched)
        let stick = URL(fileURLWithPath: "/Volumes/Stick")
        watched.morePlaces = [Place(name: "Stick", url: stick, kind: .externalDisk, canBeEjected: true)]
        weak var gone: PanelCoordinator?
        var store: PlacesStore?
        do {
            let coordinator = PanelCoordinator(kernel: kernel, home: watched.url("/a"))
            #expect(await AppWait.until { coordinator.places.isComplete })
            #expect(coordinator.ejectableVolume(containing: watched.url("/a/one.txt")) == nil)
            #expect(coordinator.ejectableVolume(containing: stick.appendingPathComponent("photos"))?.name == "Stick")
            store = coordinator.places
            gone = coordinator
            for panel in [coordinator.leftPanel, coordinator.rightPanel] {
                panel.cancelLoading()
            }
        }
        defer { store?.stop() }
        #expect(await AppWait.until { gone == nil })
        let asked = watched.placesAskedOnMain.count
        watched.morePlaces = []
        store?.refresh()
        #expect(await AppWait.until { watched.placesAskedOnMain.count > asked })
        await PanelWait.drainMainQueue()
        #expect(store?.all.map(\.name) == ["Watched"])
        // A store without file systems is complete at once; one that is let go of stops listening.
        let empty = Kernel(productName: "Test", settings: MemorySettings(), interaction: ScriptedInteraction())
        weak var released: PlacesStore?
        autoreleasepool {
            let none = PlacesStore(fileSystems: empty.fileSystems)
            #expect(none.isComplete && none.all.isEmpty)
            released = none
        }
        #expect(await AppWait.until { released == nil })
    }
}
