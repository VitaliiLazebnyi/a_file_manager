import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import PlacesPlugin

/// Hotlist and history driven through their commands, with scripted answers to the lists.
@MainActor
@Suite
internal struct PlacesCommands {
    /// The clock the plugin reads, moved on by the tests.
    internal final class Clock {
        /// The time it tells.
        internal var time = Date(timeIntervalSince1970: 5_000)

        deinit {
            // Nothing to release.
        }
    }

    /// Records the commands hotlist entries run.
    internal final class Recorder: Plugin {
        /// The plugin's name.
        internal let name = "Recorder"
        /// The arguments `cm_Recorded` was run with, in order.
        internal var arguments: [CommandArgument] = []

        /// Registers `cm_Recorded`.
        internal func start(in kernel: Kernel) {
            kernel.commands.register(Command("cm_Recorded", "Recorded")) { [self] (argument: CommandArgument) in
                arguments.append(argument)
            }
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The file system of the panels: `/A` with `docs/deep`, `/B` and `/C`.
    internal let memory = MemoryFileSystem()
    /// The settings the plugin reads and writes.
    internal let settings = MemorySettings()
    /// The plugin's clock.
    internal let clock = Clock()
    /// The plugin, with its trees in memory and the Desktop as its one Favorite.
    internal let plugin: PlacesPlugin
    /// The kernel with the plugin and the recorder; the panels show `/A` and `/B`.
    internal let bench: TestBench

    /// The plugin that records `cm_Recorded`.
    internal let recorder = Recorder()
    /// The kernel's commands.
    internal var commands: CommandRegistry { bench.commands }
    /// The left panel, the source.
    internal var left: FakePanel { bench.left }
    /// The right panel.
    internal var right: FakePanel { bench.right }
    /// The scripted answers to the lists, and what was shown.
    internal var interaction: ScriptedInteraction { bench.interaction }
    /// The hotlist as the plugin has it.
    internal var hotlist: Hotlist { plugin.hotlist(in: bench.kernel) }

    /// The rows of the list that was shown last.
    internal var lastRows: [String] {
        guard case .list(let rows, _)? = interaction.forms.last?.first?.kind else {
            return []
        }
        return rows
    }

    /// The kernel with the plugin and the recorder.
    internal init() {
        memory.addFile("/A/one.txt")
        memory.addFile("/A/docs/deep/in.txt")
        memory.addFile("/B/two.txt")
        memory.addDirectory("/C")
        let favorites = [HotlistEntry.item("Desktop", command: "cd mem:/C")]
        plugin = PlacesPlugin(keepsTreesOnDisk: false, favorites: favorites) { [clock] in clock.time }
        bench = TestBench(
            plugins: [plugin, recorder],
            fileSystems: [memory],
            left: memory.url("/A"),
            right: memory.url("/B"),
            settings: settings
        )
    }

    /// The answer to a list that picks `row` with the button at `button`.
    internal func pick(_ row: Int, button: Int) -> ScriptedInteraction.FormAnswer {
        .values(["row": .index(row)], button: button)
    }

    /// The answer to a list that picks `row` with the first button.
    internal func pick(_ row: Int) -> ScriptedInteraction.FormAnswer {
        pick(row, button: 0)
    }

    /// Stores `list` as the hotlist, as the plugin would.
    internal func store(_ list: Hotlist) {
        settings.scoped(to: "places").set(list, forKey: PlacesPlugin.Keys.hotlist)
    }

    /// Moves a panel `seconds` after the last move and announces it, as the window shell does.
    internal func go(_ panel: FakePanel, _ path: String, after seconds: TimeInterval) {
        clock.time += seconds
        panel.show(memory.url(path))
        bench.kernel.panelEvents.post(.locationChanged, from: panel)
    }

    /// Moves a panel ten seconds after the last move, long enough to count as a stay, and
    /// announces it.
    internal func go(_ panel: FakePanel, _ path: String) {
        go(panel, path, after: 10)
    }

    /// The plugin registers its commands with their keys, menu items, toolbar buttons and a preferences page.
    @Test
    internal func registersCommandsKeysMenuButtonsAndPreferences() {
        let keys = bench.kernel.keyBindings
        #expect(keys.command(for: Shortcut(.character("d"), .control)) == .directoryHotlist)
        #expect(keys.command(for: Shortcut(.downArrow, .option)) == .directoryHistory)
        #expect(keys.command(for: Shortcut(.downArrow, [.option, .shift])) == .directoryHistoryUnthinned)
        #expect(keys.command(for: .f(10, .option)) == .directoryTree)
        #expect(bench.kernel.keyClashes.isEmpty)
        #expect(
            bench.kernel.menus.menus.first { $0.title == "Commands" }?.items == [
                .directoryTree, .directoryHotlist, .directoryHistory
            ]
        )
        #expect(
            bench.kernel.toolbar.defaultLayout.compactMap { $0?.command } == [
                .directoryHotlist, .directoryHistory, .directoryTree
            ]
        )
        #expect(bench.kernel.preferences.pages.map(\.title) == ["Hotlist and History"])
        #expect(CommandID.directoryTree.rawValue == "cm_CDtree")
    }

    /// The fixed items add the current folder and remove it again, and the list is kept in the settings.
    @Test
    internal func addsAndRemovesTheCurrentDirectory() {
        interaction.formAnswers = [pick(1)]
        commands.perform(.directoryHotlist)
        #expect(lastRows == ["    Favorites  ▸", "+ Add current dir", "* Configure…"])
        #expect(hotlist.entries == [.item("A", command: "cd mem:/A")])

        // The entry of the current directory is marked, and the fixed item now removes it.
        interaction.formAnswers = [pick(3)]
        commands.perform(.directoryHotlist)
        #expect(
            lastRows == ["✓ A", HotlistMenu.separatorTitle, "    Favorites  ▸", "− Remove current dir", "* Configure…"]
        )
        #expect(hotlist.entries.isEmpty)

        commands.perform(.toggleHotlistEntry)
        commands.perform(.toggleHotlistEntry)
        #expect(hotlist.entries.isEmpty)
        // The list survives in the settings.
        commands.perform(.toggleHotlistEntry)
        #expect(settings.scoped(to: "places").value(Hotlist.self, forKey: "hotlist")?.entries.count == 1)
    }

    /// An entry changes the folder of the source panel and, with a target, of the other one.
    @Test
    internal func choosingAnEntryChangesDirectoryAndTheTargetPanel() {
        store(
            Hotlist(entries: [
                .item("Docs", command: "cd mem:/A/docs", target: "cd mem:/C"),
                .item("Focus", command: "cd mem:/A/docs/:")
            ])
        )
        interaction.formAnswers = [pick(0)]
        commands.perform(.directoryHotlist)
        #expect(left.model.directory == memory.url("/A/docs") && right.model.directory == memory.url("/C"))

        // `/:` at the end goes to the parent with the cursor on the folder.
        interaction.formAnswers = [pick(1)]
        commands.perform(.directoryHotlist)
        #expect(left.model.directory == memory.url("/A") && left.model.cursorItem?.name == "docs")
        #expect(right.model.directory == memory.url("/C"))
    }

    /// The second button opens the entry in a new tab.
    @Test
    internal func secondButtonOpensTheEntryInANewTab() {
        store(Hotlist(entries: [.item("C", command: "cd mem:/C")]))
        interaction.formAnswers = [pick(0, button: 1)]
        commands.perform(.directoryHotlist)
        #expect(left.tabs.count == 2 && left.tabs.activeIndex == 1)
        #expect(left.model.directory == memory.url("/C") && left.tabs.tabs[0].directory == memory.url("/A"))
    }

    /// Entries run commands with their arguments; an unknown command is refused.
    @Test
    internal func entriesRunCommands() {
        store(
            Hotlist(entries: [
                .item("Run", command: "cm_Recorded 3"), .item("Plain", command: "cm_Recorded"),
                .item("Unknown", command: "cm_NoSuchCommand")
            ])
        )
        var rejected = 0
        commands.onRejected = { rejected += 1 }
        for row in 0..<3 {
            interaction.formAnswers = [pick(row)]
            commands.perform(.directoryHotlist)
        }
        #expect(recorder.arguments == [.index(3), .nothing] && rejected == 1)
        #expect(left.model.directory == memory.url("/A"))
    }

    /// A submenu opens as the next list, Cancel leads back, and inside it the current folder is added and removed.
    @Test
    internal func submenusOpenAsTheNextListAndCancelLeadsBack() {
        store(Hotlist(entries: [.submenu("Sub", [.item("C", command: "cd mem:/C")]), .separator]))
        // Into the submenu, back out with Cancel, onto the separator (nothing), in again, add here.
        interaction.formAnswers = [pick(0), .cancel, pick(1), pick(0), pick(2)]
        commands.perform(.directoryHotlist)
        #expect(
            interaction.log.filter { $0.hasPrefix("form:") } == [
                "form: Directory Hotlist", "form: Directory Hotlist › Sub", "form: Directory Hotlist",
                "form: Directory Hotlist", "form: Directory Hotlist › Sub"
            ]
        )
        #expect(lastRows == ["    C", HotlistMenu.separatorTitle, "+ Add current dir", "* Configure…"])
        #expect(hotlist.children(of: [0]).map(\.title) == ["C", "A"])

        interaction.formAnswers = [pick(0), pick(0)]
        commands.perform(.directoryHotlist)
        #expect(left.model.directory == memory.url("/C"))
        // In /C the submenu is marked and selected, and inside it the entry can be removed.
        interaction.formAnswers = [pick(0), pick(3)]
        commands.perform(.directoryHotlist)
        #expect(lastRows == ["✓ C", "    A", HotlistMenu.separatorTitle, "− Remove current dir", "* Configure…"])
        #expect(hotlist.children(of: [0]).map(\.title) == ["A"])
    }

    /// The Favorites are offered unless they are switched off.
    @Test
    internal func favoritesAreOfferedUnlessSwitchedOff() {
        interaction.formAnswers = [pick(0), pick(0)]
        commands.perform(.directoryHotlist)
        #expect(lastRows == ["    Desktop"] && left.model.directory == memory.url("/C"))

        settings.set(false, forKey: PlacesPlugin.Keys.favorites)
        interaction.formAnswers = [.cancel]
        commands.perform(.directoryHotlist)
        #expect(lastRows == ["+ Add current dir", "* Configure…"])
    }

    /// Hidden entries stay out of the menu.
    @Test
    internal func hiddenEntriesStayOutOfTheMenu() {
        store(
            Hotlist(
                entries: [.item("?Secret", command: "cd mem:/C"), .item("B", command: "cd mem:/B")],
                hidesMarked: true
            )
        )
        interaction.formAnswers = [pick(0)]
        commands.perform(.directoryHotlist)
        #expect(lastRows.first == "    B" && left.model.directory == memory.url("/B"))
    }

    /// Configure stores what the editor gives back, and keeps the list when the editor is cancelled.
    @Test
    internal func configureStoresWhatTheEditorReturnsAndKeepsTheListOnCancel() {
        var shown: [Hotlist] = []
        plugin.editHotlist = { list in
            shown.append(list)
            return Hotlist(
                entries: list.entries + [.item("Edited", command: "cd mem:/B")],
                hideCharacter: "!",
                hidesMarked: true
            )
        }
        interaction.formAnswers = [pick(2)]
        commands.perform(.directoryHotlist)
        #expect(shown == [Hotlist()] && hotlist.entries.map(\.title) == ["Edited"] && hotlist.hideCharacter == "!")
        plugin.editHotlist = { _ in nil }
        commands.perform(.configureHotlist)
        #expect(hotlist.entries.map(\.title) == ["Edited"])
    }
}
