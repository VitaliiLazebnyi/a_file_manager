import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The bars of a panel through the real program: the path bar, the folder tabs and the drive
/// line with its volume list (spec 03 › Panel anatomy).
@MainActor
@Suite(.serialized)
internal struct PanelBarsTests {
    private let program: PanelProgram

    /// The program's folders, with `B/fresh.txt` and a file in the memory file system.
    internal init() throws {
        program = try PanelProgram(rightFile: "fresh.txt", contents: "fresh")
        program.memory.addFile("/M/remote.txt", "far")
    }

    /// Starts the program with the plugins a file manager cannot do without.
    private func start() async -> PanelProgram.Running {
        await program.start(plugins: CorePlugins.make(pasteboard: program.scratch.pasteboard), fileSystems: [])
    }

    /// The middle of segment `index` of a path bar as drawn.
    private func center(of index: Int, in bar: PathBarView) -> NSPoint {
        NSPoint(x: bar.textOrigin + (bar.spans[index].minX + bar.spans[index].maxX) / 2, y: bar.bounds.midY)
    }

    /// The button of the drive line that runs `command`.
    private func button(_ command: CommandID, in view: NSView) -> NSButton? {
        for subview in view.subviews {
            if let button = subview as? NSButton, button.identifier?.rawValue == command.rawValue {
                return button
            }
            if let found = button(command, in: subview) {
                return found
            }
        }
        return nil
    }

    /// The path bar leads to the folders above, makes its panel the source, edits the path on
    /// a double click, copies it from its menu, and writes other file systems' paths their way.
    @Test
    internal func thePathBarLeadsToTheFoldersAbove() async {
        let app = await start()
        defer { app.stop() }
        app.layOut()
        let bar = app.left.pathBar
        #expect(app.left.pathBarText == program.box.url("A").path + "/*.*")
        #expect(
            bar.segments.last?.location.path == program.box.url("A").path && bar.segments.first?.location.path == "/"
        )
        // A click in the right panel's bar goes up there and makes that panel the source.
        let rightBar = app.right.pathBar
        rightBar.click(at: center(of: rightBar.segments.count - 2, in: rightBar), count: 1)
        await program.settle(app)
        #expect(app.right.model.directory.path == program.box.root.path && app.kernel.panels.source === app.right)
        #expect(app.right.pathBarText == program.box.root.path + "/*.*")
        // A double click on the bar edits the path.
        program.interaction.promptAnswers = [.text(program.box.url("A/docs").path)]
        bar.click(at: NSPoint(x: bar.bounds.maxX - 3, y: 10), count: 2)
        await program.settle(app)
        #expect(app.left.model.directory.lastPathComponent == "docs" && app.kernel.panels.source === app.left)
        // The menu copies the path.
        let menu = app.left.pathMenu()
        #expect(menu.items.map(\.title).starts(with: ["Copy Path", "", "Go to Folder…"]))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        app.left.copyPath(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == program.box.url("A/docs").path)
        // Other file systems write their paths their own way.
        app.left.show(program.memory.url("/M"))
        await program.settle(app)
        #expect(app.left.pathBarText == "mem:/M/*.*" && bar.segments.map(\.location.path) == ["/", "/M"])
    }

    /// Tabs have a menu that shows the tab first, can be moved (not while a job runs), and show
    /// the titles and marks the model gives them.
    @Test
    internal func tabsHaveAMenuAndCanBeMoved() async {
        let app = await start()
        defer { app.stop() }
        app.commands.perform(.newTab, .nothing)
        app.commands.perform(.changeDirectory, .location(program.box.url("A/docs")))
        await program.settle(app)
        app.left.tabs.insertTab(showing: program.box.url("home"), activate: false)
        #expect(
            app.left.tabBar.stack.arrangedSubviews.count == 3 && !app.left.tabBar.isHidden && app.right.tabBar.isHidden
        )
        // The menu of a tab shows that tab and offers the commands the plugins registered.
        let menu = app.left.tabMenu(forTab: 0)?.items.map(\.title) ?? []
        await program.settle(app)
        #expect(app.left.tabs.activeIndex == 0)
        #expect(["New Folder Tab", "Close Tab", "Next Tab", "Previous Tab"].allSatisfy(menu.contains))
        app.left.moveTab(from: 0, to: 2)
        #expect(app.left.tabs.activeIndex == 2)
        // Custom titles and the mark of locked tabs come from the model.
        app.left.tabs.tabs[0].customTitle = "Papers"
        app.left.tabs.tabs[0].isLocked = true
        app.left.tabs.activate(0)
        await program.settle(app)
        let titles = app.left.tabBar.stack.arrangedSubviews.compactMap { ($0 as? NSButton)?.title }
        #expect(titles == ["*Papers", "home", "A"])
        // While a job runs, a tab is neither moved nor offers a menu.
        app.commands.isBlocked = { true }
        app.left.moveTab(from: 0, to: 2)
        #expect(app.left.tabMenu(forTab: 1) == nil && app.left.tabs.activeIndex == 0)
        app.commands.isBlocked = { false }
        // The strip's own clicks are the panel's tab commands.
        app.left.tabBar.onSelect?(1)
        #expect(app.left.tabs.activeIndex == 1)
        app.left.tabBar.onNewTab?()
        app.left.tabBar.onClose?(app.left.tabs.activeIndex)
        app.left.tabBar.onMove?(0, 1)
        #expect(app.left.tabBar.menuProvider?(0) != nil)
        await program.settle(app)
    }

    /// The drive line goes to the root and the parent folder, shows the volume and its free
    /// space, and opens the volume list with the places the coordinator knows.
    @Test
    internal func theDriveLineLeadsToTheVolumesAndTheFoldersAbove() async throws {
        let app = await start()
        defer { app.stop() }
        app.layOut()
        try #require(button(.goToParent, in: app.left.view)).performClick(nil)
        await program.settle(app)
        #expect(app.left.model.directory.path == program.box.root.path)
        try #require(button(.goToRoot, in: app.left.view)).performClick(nil)
        await program.settle(app)
        #expect(app.left.model.directory.path == "/")
        // The volume list: the places, disks apart, each leading there.
        let menu = try #require(app.left.volumeButton.menu)
        app.left.menuNeedsUpdate(menu)
        app.left.menuWillOpen(menu)
        app.left.placesDidChange()
        app.left.menuDidClose(menu)
        let places = menu.items.filter { $0.representedObject is URL }
        #expect(!places.isEmpty && places.allSatisfy { $0.image != nil })
        let memory = try #require(places.first { ($0.representedObject as? URL)?.scheme == "mem" })
        _ = memory.target?.perform(memory.action, with: memory)
        await program.settle(app)
        #expect(app.left.model.directory.scheme == "mem")
        app.left.menuNeedsUpdate(NSMenu())
    }
}
