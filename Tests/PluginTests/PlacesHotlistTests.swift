import AFMContracts
import AFMKernel
import Foundation
@testable import PlacesPlugin
import TestSupport
import Testing

/// The hotlist as a value: entries, submenus, moving, hiding and what an entry's command means.
@Suite struct PlacesHotlistModel {
    func sample() -> Hotlist {
        Hotlist(entries: [
            .item("&Work", command: "cd /work"),
            .submenu("Projects", [.item("App", command: "cd /src/app/:"), .submenu("Old", [.item("Legacy", command: "cd /old")])]),
            .separator,
            .item("?Secret", command: "cd /secret"),
        ])
    }

    @Test func rowsListEveryEntryWithItsDepth() {
        let list = sample()
        #expect(list.rows.map(\.path) == [[0], [1], [1, 0], [1, 1], [1, 1, 0], [2], [3]])
        #expect(list.rows.map(\.depth) == [0, 0, 1, 1, 2, 0, 0])
        #expect(list.entry(at: [1, 1, 0])?.title == "Legacy")
        #expect(list.entry(at: [1, 5]) == nil && list.entry(at: []) == nil)
        #expect(list.children(of: [1]).map(\.title) == ["App", "Old"])
        #expect(list.entries[0].displayTitle == "Work")
        #expect(HotlistEntry.item("R&&D", command: "").displayTitle == "R&D")
    }

    @Test func insertRemoveAndUpdate() {
        var list = sample()
        let inserted = list.insert(.item("New", command: "cd /new"), at: [1, 1])
        #expect(inserted == [1, 1])
        #expect(list.children(of: [1]).map(\.title) == ["App", "New", "Old"])
        let appended = list.insert(.separator, at: [99])
        // An item is not a level, so nothing can be put inside it.
        let refused = list.insert(.separator, at: [0, 0])
        #expect(appended == [4] && refused == nil)
        let removed = list.remove(at: [1, 1])
        let missing = list.remove(at: [7])
        #expect(removed?.title == "New" && missing == nil)
        let updated = list.update(at: [0]) { $0.target = "/backup" }
        #expect(updated)
        #expect(list.entries[0].target == "/backup")
        #expect(HotlistEntry.titled("-", command: "cd /x") == .separator)
        #expect(HotlistEntry.titled("Docs", command: "cd /x").kind == .item)
    }

    @Test func addingToASubmenuGoesBeforeTheSubmenusItEndsWith() {
        var list = sample()
        let inSubmenu = list.add(.item("Tools", command: "cd /tools"), to: [1])
        #expect(inSubmenu == [1, 1])
        #expect(list.children(of: [1]).map(\.title) == ["App", "Tools", "Old"])
        let atEnd = list.add(.item("Last", command: "cd /last"), to: [])
        #expect(atEnd == [4])
    }

    @Test func theListTakesNoMoreThanItsLimit() {
        var list = Hotlist(entries: (0..<Hotlist.limit).map { .item("e\($0)", command: "cd /e\($0)") })
        let refused = list.add(.separator, to: [])
        #expect(refused == nil)
        #expect(list.count == Hotlist.limit)
    }

    @Test func movingWalksThroughSubmenusLikeAFlatList() {
        var list = sample()
        // Down from the top: into the submenu, through it, into the inner one, and out again.
        var path = list.move(at: [0], by: 1)
        #expect(path == [0, 0] && list.rows.map(\.entry.title) == ["Projects", "&Work", "App", "Old", "Legacy", "-", "?Secret"])
        path = list.move(at: path, by: 1)
        #expect(path == [0, 1])
        path = list.move(at: path, by: 1)
        #expect(path == [0, 1, 0])
        path = list.move(at: path, by: 1)
        #expect(path == [0, 1, 1])
        path = list.move(at: path, by: 1)
        #expect(path == [0, 2])
        path = list.move(at: path, by: 1)
        #expect(path == [1] && list.entries.map(\.title) == ["Projects", "&Work", "-", "?Secret"])
        // And all the way back up.
        for _ in 0..<6 { path = list.move(at: path, by: -1) }
        #expect(path == [0] && list == sample())
        // The first line cannot go further up, the last not further down.
        let (first, last) = (list.move(at: [0], by: -1), list.move(at: [3], by: 1))
        #expect(first == [0] && last == [3] && list == sample())
    }

    @Test func hiding() {
        var list = sample()
        #expect(!list.isHidden(list.entries[3]))
        list.hidesMarked = true
        #expect(list.isHidden(list.entries[3]) && !list.isHidden(list.entries[0]))
        list.toggleHideMark(at: [3])
        #expect(list.entries[3].title == "Secret" && !list.isHidden(list.entries[3]))
        list.toggleHideMark(at: [1])
        #expect(list.entries[1].title == "?Projects")
        list.toggleHideMark(at: [2])
        #expect(list.entries[2] == .separator)
        let menu = HotlistMenu(list) { _ in false }
        #expect(menu.titles == ["    Work", HotlistMenu.separatorTitle, "    Secret", HotlistMenu.separatorTitle, "+ Add current dir", "* Configure…"])
    }

    @Test func storedAsJSONAndReadBack() throws {
        let data = try JSONEncoder().encode(sample())
        #expect(try JSONDecoder().decode(Hotlist.self, from: data) == sample())
    }

    @Test func actions() {
        #expect(HotlistAction("cd /Users/x/dir") == .changeDirectory(path: "/Users/x/dir", focusingOnIt: false))
        #expect(HotlistAction("CD  \"/with space\"") == .changeDirectory(path: "/with space", focusingOnIt: false))
        #expect(HotlistAction("cd /Dir/Focusme/:") == .changeDirectory(path: "/Dir/Focusme", focusingOnIt: true))
        #expect(HotlistAction("/plain/path") == .changeDirectory(path: "/plain/path", focusingOnIt: false))
        #expect(HotlistAction("cm_GoToRoot") == .command("cm_GoToRoot", .none))
        #expect(HotlistAction("cm_SrcActivateTab 2") == .command("cm_SrcActivateTab", .index(2)))
        #expect(HotlistAction("afm_Something some text") == .command("afm_Something", .text("some text")))
        #expect(HotlistAction("   ") == .nothing)
        #expect(HotlistAction.targetPath("cd /backup") == "/backup" && HotlistAction.targetPath("/backup") == "/backup")
        #expect(HotlistAction.targetPath("") == nil && HotlistAction.targetPath("cm_GoToRoot") == nil)
    }

    @Test func menuMarksTheCurrentDirectoryAndTheSubmenusHoldingIt() {
        let list = sample()
        let top = HotlistMenu(list, offersFavorites: true) { $0.command == "cd /old" }
        #expect(top.titles == ["    Work", "✓ Projects  ▸", HotlistMenu.separatorTitle, "    ?Secret", HotlistMenu.separatorTitle,
                               "    Favorites  ▸", "+ Add current dir", "* Configure…"])
        #expect(top.selected == 1 && top.rows[1].action == .open([1]) && top.rows[5].action == .openFavorites)
        let inner = HotlistMenu(list, at: [1, 1], offersFavorites: true) { $0.command == "cd /old" }
        #expect(inner.titles == ["✓ Legacy", HotlistMenu.separatorTitle, "− Remove current dir", "* Configure…"])
        #expect(inner.rows[2].action == .removeCurrent([1, 1, 0]))
        #expect(HotlistMenu(Hotlist()) { _ in false }.titles == ["+ Add current dir", "* Configure…"])
        let places = HotlistMenu(places: MacFavorites.entries(home: URL(fileURLWithPath: "/Users/x"))) { $0.command == "cd /Users/x/Desktop" }
        #expect(places.titles.prefix(3) == ["    Home", "    Applications", "✓ Desktop"] && places.selected == 2)
    }

    @Test func editorListIndentsSubmenus() {
        #expect(sample().rows.map(HotlistEditorWindowController.title(of:))
                == ["&Work", "▾ Projects", "      App", "      ▾ Old", "            Legacy", HotlistMenu.separatorTitle, "?Secret"])
    }
}

/// The history of a panel and the frequently used folders, as values.
@Suite struct PlacesHistoryModel {
    func url(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: false) }

    @Test func recordsEveryPlaceOnceTheLastVisitedLast() {
        var history = DirectoryHistory()
        let (first, again) = (history.record(url("/a"), stayedInPrevious: false), history.record(url("/a/"), stayedInPrevious: true))
        #expect(first && !again)
        history.record(url("/b"), stayedInPrevious: true)
        history.record(url("/c"), stayedInPrevious: false)
        history.record(url("/a"), stayedInPrevious: true)
        #expect(history.visits.map(\.location) == ["file:///b", "file:///c", "file:///a"])
        #expect(history.current == url("/a"))
        #expect(history.shown(thinning: false).map(\.path) == ["/a", "/c", "/b"])
        #expect(history.shown(thinning: false, limit: 2).map(\.path) == ["/a", "/c"])
    }

    @Test func thinningHidesFoldersThatWereOnlyPassedThrough() {
        var history = DirectoryHistory()
        history.record(url("/a"), stayedInPrevious: false)
        history.record(url("/a/b"), stayedInPrevious: true)      // stayed in /a
        history.record(url("/a/b/c"), stayedInPrevious: false)   // passed through /a/b
        history.record(url("/a/b/c/d"), stayedInPrevious: false) // passed through /a/b/c
        #expect(history.shown(thinning: true).map(\.path) == ["/a/b/c/d", "/a"])
        #expect(history.shown(thinning: false).count == 4)
        // A folder that once counted keeps counting when it is passed through later.
        history.record(url("/a"), stayedInPrevious: false)
        history.record(url("/z"), stayedInPrevious: false)
        #expect(history.shown(thinning: true).map(\.path) == ["/z", "/a"])
        history.remove(url("/a"))
        #expect(history.shown(thinning: false).map(\.path) == ["/z", "/a/b/c/d", "/a/b/c", "/a/b"])
    }

    @Test func keepsNoMoreThanTheStoredLimit() {
        var history = DirectoryHistory()
        for index in 0..<(DirectoryHistory.storedLimit + 20) { history.record(url("/d\(index)"), stayedInPrevious: true) }
        #expect(history.visits.count == DirectoryHistory.storedLimit)
        #expect(history.visits.first?.location == "file:///d20")
    }

    @Test func frequentFoldersAreRankedByVisits() {
        var frequent = FrequentFolders()
        for path in ["/a", "/b", "/a", "/c", "/a", "/b"] { frequent.record(url(path)) }
        #expect(frequent.top().map(\.directory.path) == ["/a", "/b", "/c"])
        #expect(frequent.top().map(\.visits) == [3, 2, 1])
        #expect(frequent.top(1).map(\.directory.path) == ["/a"])
        frequent.remove(url("/a"))
        #expect(frequent.top().map(\.directory.path) == ["/b", "/c"])
        for index in 0..<(FrequentFolders.storedLimit + 10) { frequent.record(url("/n\(index)")) }
        #expect(frequent.counts.count == FrequentFolders.storedLimit && frequent.top(1).first?.directory.path == "/b")
    }

    @Test func menuListsHistoryThenFrequentFolders() {
        let menu = HistoryMenu(history: [url("/b"), url("/a")], frequent: [(url("/a"), 7)], current: url("/a")) { $0.path }
        #expect(menu.titles == ["    /b", "➤ /a", "──────  Frequently used  ──────", "    /a   (7)"])
        #expect(menu.rows == [.visit(url("/b")), .visit(url("/a")), .separator, .frequent(url("/a"))])
        #expect(menu.selected == 1 && menu.rows[2].directory == nil)
        #expect(HistoryMenu(history: [], frequent: [], current: url("/a")) { $0.path }.rows.isEmpty)
    }

    @MainActor @Test func trackerMeasuresStaysAndSavesToTheSettings() {
        let settings = MemorySettings()
        var time = Date(timeIntervalSince1970: 1000)
        let tracker = DirectoryHistoryTracker(settings: settings) { time }
        tracker.visited(url("/a"), on: .left)
        time += 10
        tracker.visited(url("/b"), on: .left)
        time += 1
        tracker.visited(url("/c"), on: .left)
        tracker.visited(url("/c"), on: .left)
        tracker.visited(url("/r"), on: .right)
        #expect(tracker.history(of: .left).shown(thinning: true).map(\.path) == ["/c", "/a"])
        #expect(tracker.history(of: .right).shown(thinning: true).map(\.path) == ["/r"])
        #expect(tracker.frequent.top().map(\.visits) == [1, 1, 1, 1])

        // Changes are written shortly after a burst of navigation, or on request.
        tracker.flush()
        let restarted = DirectoryHistoryTracker(settings: settings) { time }
        #expect(restarted.history(of: .left) == tracker.history(of: .left) && restarted.frequent == tracker.frequent)
        restarted.remove(url("/a"), from: .left)
        restarted.removeFrequent(url("/r"))
        #expect(restarted.history(of: .left).shown(thinning: false).map(\.path) == ["/c", "/b"])
        #expect(restarted.frequent.top().count == 3)
        restarted.clear()
        #expect(DirectoryHistoryTracker(settings: settings).history(of: .left).visits.isEmpty)

        // With saving off, nothing reaches the settings until "Save now".
        let quiet = DirectoryHistoryTracker(settings: settings) { time }
        quiet.savesChanges = { false }
        quiet.visited(url("/q"), on: .right)
        quiet.flush()
        #expect(DirectoryHistoryTracker(settings: settings).history(of: .right).visits.isEmpty)
        quiet.save()
        #expect(DirectoryHistoryTracker(settings: settings).history(of: .right).current == url("/q"))
    }
}

/// Hotlist and history driven through their commands, with scripted answers to the lists.
@MainActor @Suite struct PlacesCommands {
    let memory = MemoryFileSystem()
    let settings = MemorySettings()
    let clock = Clock()
    let plugin: PlacesPlugin
    let bench: TestBench

    final class Clock {
        var time = Date(timeIntervalSince1970: 5000)
    }

    /// Records the commands hotlist entries run.
    final class Recorder: Plugin {
        let name = "Recorder"
        var arguments: [CommandArgument] = []

        func start(in kernel: Kernel) {
            kernel.commands.register(Command("cm_Recorded", "Recorded"), parameterized: { [self] in arguments.append($0) })
        }
    }

    let recorder = Recorder()
    var commands: CommandRegistry { bench.commands }
    var left: FakePanel { bench.left }
    var right: FakePanel { bench.right }
    var ui: ScriptedInteraction { bench.ui }
    var hotlist: Hotlist { plugin.hotlist(in: bench.kernel) }

    init() {
        memory.addFile("/A/one.txt")
        memory.addFile("/A/docs/deep/in.txt")
        memory.addFile("/B/two.txt")
        memory.addDirectory("/C")
        let favorites = [HotlistEntry.item("Desktop", command: "cd mem:/C")]
        plugin = PlacesPlugin(keepsTreesOnDisk: false, favorites: favorites, now: { [clock] in clock.time })
        bench = TestBench(plugins: [plugin, recorder], fileSystems: [memory], left: memory.url("/A"), right: memory.url("/B"), settings: settings)
    }

    func pick(_ row: Int, button: Int = 0) -> ScriptedInteraction.FormAnswer {
        .values(["row": .index(row)], button: button)
    }

    /// The rows of the list that was shown last.
    var lastRows: [String] {
        guard case .list(let rows, _)? = ui.forms.last?.first?.kind else { return [] }
        return rows
    }

    func store(_ list: Hotlist) {
        settings.scoped(to: "places").set(list, forKey: PlacesPlugin.Keys.hotlist)
    }

    /// Moves a panel and announces it, as the window shell does.
    func go(_ panel: FakePanel, _ path: String, after seconds: TimeInterval = 10) {
        clock.time += seconds
        panel.show(memory.url(path))
        bench.kernel.panelEvents.post(.locationChanged, from: panel)
    }

    @Test func registersCommandsKeysMenuButtonsAndPreferences() {
        let keys = bench.kernel.keyBindings
        #expect(keys.command(for: Shortcut(.character("d"), .control)) == .directoryHotlist)
        #expect(keys.command(for: Shortcut(.down, .option)) == .directoryHistory)
        #expect(keys.command(for: Shortcut(.down, [.option, .shift])) == .directoryHistoryUnthinned)
        #expect(keys.command(for: .f(10, .option)) == .directoryTree)
        #expect(keys.conflicts.isEmpty)
        #expect(bench.kernel.menus.menus.first { $0.title == "Commands" }?.items == [.directoryTree, .directoryHotlist, .directoryHistory])
        #expect(bench.kernel.toolbar.defaultLayout.compactMap { $0?.command } == [.directoryHotlist, .directoryHistory, .directoryTree])
        #expect(bench.kernel.preferences.pages.map(\.title) == ["Hotlist and History"])
        #expect(CommandID.directoryTree.rawValue == "cm_CDtree")
    }

    @Test func addsAndRemovesTheCurrentDirectory() {
        ui.formAnswers = [pick(1)]
        commands.perform(.directoryHotlist)
        #expect(lastRows == ["    Favorites  ▸", "+ Add current dir", "* Configure…"])
        #expect(hotlist.entries == [.item("A", command: "cd mem:/A")])

        // The entry of the current directory is marked, and the fixed item now removes it.
        ui.formAnswers = [pick(3)]
        commands.perform(.directoryHotlist)
        #expect(lastRows == ["✓ A", HotlistMenu.separatorTitle, "    Favorites  ▸", "− Remove current dir", "* Configure…"])
        #expect(hotlist.entries.isEmpty)

        commands.perform(.toggleHotlistEntry)
        commands.perform(.toggleHotlistEntry)
        #expect(hotlist.entries.isEmpty)
        // The list survives in the settings.
        commands.perform(.toggleHotlistEntry)
        #expect(settings.scoped(to: "places").value(Hotlist.self, forKey: "hotlist")?.entries.count == 1)
    }

    @Test func choosingAnEntryChangesDirectoryAndTheTargetPanel() {
        store(Hotlist(entries: [.item("Docs", command: "cd mem:/A/docs", target: "cd mem:/C"), .item("Focus", command: "cd mem:/A/docs/:")]))
        ui.formAnswers = [pick(0)]
        commands.perform(.directoryHotlist)
        #expect(left.model.directory == memory.url("/A/docs") && right.model.directory == memory.url("/C"))

        // `/:` at the end goes to the parent with the cursor on the folder.
        ui.formAnswers = [pick(1)]
        commands.perform(.directoryHotlist)
        #expect(left.model.directory == memory.url("/A") && left.model.cursorItem?.name == "docs")
        #expect(right.model.directory == memory.url("/C"))
    }

    @Test func secondButtonOpensTheEntryInANewTab() {
        store(Hotlist(entries: [.item("C", command: "cd mem:/C")]))
        ui.formAnswers = [pick(0, button: 1)]
        commands.perform(.directoryHotlist)
        #expect(left.tabs.count == 2 && left.tabs.activeIndex == 1)
        #expect(left.model.directory == memory.url("/C") && left.tabs.tabs[0].directory == memory.url("/A"))
    }

    @Test func entriesRunCommands() {
        store(Hotlist(entries: [.item("Run", command: "cm_Recorded 3"), .item("Plain", command: "cm_Recorded"),
                                .item("Unknown", command: "cm_NoSuchCommand")]))
        var rejected = 0
        commands.onRejected = { rejected += 1 }
        for row in 0..<3 {
            ui.formAnswers = [pick(row)]
            commands.perform(.directoryHotlist)
        }
        #expect(recorder.arguments == [.index(3), .none] && rejected == 1)
        #expect(left.model.directory == memory.url("/A"))
    }

    @Test func submenusOpenAsTheNextListAndCancelLeadsBack() {
        store(Hotlist(entries: [.submenu("Sub", [.item("C", command: "cd mem:/C")]), .separator]))
        // Into the submenu, back out with Cancel, onto the separator (nothing), in again, add here.
        ui.formAnswers = [pick(0), .cancel, pick(1), pick(0), pick(2)]
        commands.perform(.directoryHotlist)
        #expect(ui.log.filter { $0.hasPrefix("form:") } == ["form: Directory Hotlist", "form: Directory Hotlist › Sub", "form: Directory Hotlist",
                                                            "form: Directory Hotlist", "form: Directory Hotlist › Sub"])
        #expect(lastRows == ["    C", HotlistMenu.separatorTitle, "+ Add current dir", "* Configure…"])
        #expect(hotlist.children(of: [0]).map(\.title) == ["C", "A"])

        ui.formAnswers = [pick(0), pick(0)]
        commands.perform(.directoryHotlist)
        #expect(left.model.directory == memory.url("/C"))
        // In /C the submenu is marked and selected, and inside it the entry can be removed.
        ui.formAnswers = [pick(0), pick(3)]
        commands.perform(.directoryHotlist)
        #expect(lastRows == ["✓ C", "    A", HotlistMenu.separatorTitle, "− Remove current dir", "* Configure…"])
        #expect(hotlist.children(of: [0]).map(\.title) == ["A"])
    }

    @Test func favoritesAreOfferedUnlessSwitchedOff() {
        ui.formAnswers = [pick(0), pick(0)]
        commands.perform(.directoryHotlist)
        #expect(lastRows == ["    Desktop"] && left.model.directory == memory.url("/C"))

        settings.set(false, forKey: PlacesPlugin.Keys.favorites)
        ui.formAnswers = [.cancel]
        commands.perform(.directoryHotlist)
        #expect(lastRows == ["+ Add current dir", "* Configure…"])
    }

    @Test func hiddenEntriesStayOutOfTheMenu() {
        store(Hotlist(entries: [.item("?Secret", command: "cd mem:/C"), .item("B", command: "cd mem:/B")], hidesMarked: true))
        ui.formAnswers = [pick(0)]
        commands.perform(.directoryHotlist)
        #expect(lastRows.first == "    B" && left.model.directory == memory.url("/B"))
    }

    @Test func configureStoresWhatTheEditorReturnsAndKeepsTheListOnCancel() {
        var shown: [Hotlist] = []
        plugin.editHotlist = { list in
            shown.append(list)
            return Hotlist(entries: list.entries + [.item("Edited", command: "cd mem:/B")], hideCharacter: "!", hidesMarked: true)
        }
        ui.formAnswers = [pick(2)]
        commands.perform(.directoryHotlist)
        #expect(shown == [Hotlist()] && hotlist.entries.map(\.title) == ["Edited"] && hotlist.hideCharacter == "!")
        plugin.editHotlist = { _ in nil }
        commands.perform(.configureHotlist)
        #expect(hotlist.entries.map(\.title) == ["Edited"])
    }

    // MARK: History

    @Test func historyListsTheVisitedDirectoriesOfThePanel() {
        go(left, "/A/docs")
        go(left, "/A/docs/deep")
        go(left, "/C", after: 1)
        go(right, "/C")
        // /A/docs/deep was only passed through; the source panel's own history is shown.
        ui.formAnswers = [pick(1)]
        commands.perform(.directoryHistory)
        #expect(lastRows == ["➤ mem:/C", "    mem:/A/docs", "──────  Frequently used  ──────", "    mem:/C   (2)", "    mem:/A/docs   (1)",
                             "    mem:/A/docs/deep   (1)"])
        #expect(left.model.directory == memory.url("/A/docs"))

        ui.formAnswers = [.cancel]
        commands.perform(.directoryHistoryUnthinned)
        #expect(lastRows.prefix(3) == ["➤ mem:/A/docs", "    mem:/C", "    mem:/A/docs/deep"])
    }

    @Test func historyKnowsTheCurrentDirectoryBeforeAnyEvent() {
        ui.formAnswers = [.cancel]
        commands.perform(.directoryHistory)
        #expect(lastRows == ["➤ mem:/A", "──────  Frequently used  ──────", "    mem:/A   (1)"])
    }

    @Test func historyButtonsOpenTabsAndTheOtherPanelAndRemoveEntries() {
        go(left, "/C")
        go(left, "/A")
        ui.formAnswers = [pick(1, button: 1)]
        commands.perform(.directoryHistory)
        #expect(left.tabs.count == 2 && left.model.directory == memory.url("/C"))
        // The window shell announces the new tab's directory.
        clock.time += 10
        bench.kernel.panelEvents.post(.locationChanged, from: left)

        ui.formAnswers = [pick(0, button: 2)]
        commands.perform(.directoryHistory)
        #expect(right.model.directory == memory.url("/C") && left.model.directory == memory.url("/C"))

        // Remove an entry of the history, then one of the frequent folders; the list comes back each time.
        go(left, "/A")
        ui.formAnswers = [pick(1, button: 3), pick(3, button: 3), .cancel]
        commands.perform(.directoryHistory)
        #expect(lastRows == ["➤ mem:/A", "──────  Frequently used  ──────", "    mem:/A   (2)"])
    }

    @Test func historySettingsLimitTheListAndHideFrequentFolders() {
        for path in ["/C", "/B", "/A/docs", "/A"] { go(left, path) }
        settings.set("2", forKey: PlacesPlugin.Keys.historyShown)
        settings.set(false, forKey: PlacesPlugin.Keys.showFrequent)
        ui.formAnswers = [.cancel, .cancel]
        commands.perform(.directoryHistory)
        #expect(lastRows == ["➤ mem:/A", "    mem:/A/docs"])
        settings.set(false, forKey: PlacesPlugin.Keys.thinning)
        go(left, "/C", after: 0)
        go(left, "/A", after: 0)
        commands.perform(.directoryHistory)
        #expect(lastRows == ["➤ mem:/A", "    mem:/C"])
    }

    @Test func historyIsSavedAndCleared() {
        go(left, "/C")
        // Changes are written shortly after the navigation, not on every step.
        plugin.flushHistory()
        let stored = settings.scoped(to: "places").value(DirectoryHistory.self, forKey: "history.left")
        #expect(stored?.current == memory.url("/C"))
        commands.perform(.clearDirectoryHistory)
        #expect(settings.data(forKey: "places.history.left") == nil)

        settings.set(false, forKey: PlacesPlugin.Keys.saveHistory)
        go(left, "/B")
        plugin.flushHistory()
        #expect(settings.data(forKey: "places.history.left") == nil)
        commands.perform(.saveDirectoryHistory)
        #expect(settings.scoped(to: "places").value(DirectoryHistory.self, forKey: "history.left")?.current == memory.url("/B"))
    }
}
