import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import PlacesPlugin

/// The hotlist as a value: entries, submenus, moving, hiding and what an entry's command means.
@Suite
internal struct PlacesHotlistModel {
    /// A list with a hidden-marked item, a submenu inside a submenu, a separator, and an item
    /// whose command ends in `/:`.
    internal func sample() -> Hotlist {
        Hotlist(entries: [
            .item("&Work", command: "cd /work"),
            .submenu(
                "Projects",
                [.item("App", command: "cd /src/app/:"), .submenu("Old", [.item("Legacy", command: "cd /old")])]
            ),
            .separator,
            .item("?Secret", command: "cd /secret")
        ])
    }

    /// The rows list every entry, submenus inside, with its path and depth; `&` marks no letter in the title shown.
    @Test
    internal func rowsListEveryEntryWithItsDepth() {
        let list = sample()
        #expect(list.rows.map(\.path) == [[0], [1], [1, 0], [1, 1], [1, 1, 0], [2], [3]])
        #expect(list.rows.map(\.depth) == [0, 0, 1, 1, 2, 0, 0])
        #expect(list.entry(at: [1, 1, 0])?.title == "Legacy")
        #expect(list.entry(at: [1, 5]) == nil && list.entry(at: []) == nil)
        #expect(list.children(of: [1]).map(\.title) == ["App", "Old"])
        #expect(list.entries[0].displayTitle == "Work")
        #expect(HotlistEntry.item("R&&D", command: "").displayTitle == "R&D")
    }

    /// Entries are inserted, removed and changed at their paths; nothing goes inside an item.
    @Test
    internal func insertRemoveAndUpdate() {
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

    /// An entry added to a level goes before the submenus at its end.
    @Test
    internal func addingToASubmenuGoesBeforeTheSubmenusItEndsWith() {
        var list = sample()
        let inSubmenu = list.add(.item("Tools", command: "cd /tools"), to: [1])
        #expect(inSubmenu == [1, 1])
        #expect(list.children(of: [1]).map(\.title) == ["App", "Tools", "Old"])
        let atEnd = list.add(.item("Last", command: "cd /last"), to: [])
        #expect(atEnd == [4])
    }

    /// A full list takes no more entries.
    @Test
    internal func theListTakesNoMoreThanItsLimit() {
        var list = Hotlist(entries: (0..<Hotlist.limit).map { .item("e\($0)", command: "cd /e\($0)") })
        let refused = list.add(.separator, to: [])
        #expect(refused == nil)
        #expect(list.count == Hotlist.limit)
    }

    /// Moving an entry walks it into, through and out of submenus as if the list were flat, and no further than
    /// its ends.
    @Test
    internal func movingWalksThroughSubmenusLikeAFlatList() {
        var list = sample()
        // Down from the top: into the submenu, through it, into the inner one, and out again.
        var path = list.move(at: [0], by: 1)
        #expect(
            path == [0, 0]
                && list.rows.map(\.entry.title) == ["Projects", "&Work", "App", "Old", "Legacy", "-", "?Secret"]
        )
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

    /// Entries marked with the hide character are hidden when the list hides them, and the mark is put on and
    /// taken off; a separator takes none.
    @Test
    internal func hiding() {
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
        #expect(
            menu.titles == [
                "    Work", HotlistMenu.separatorTitle, "    Secret", HotlistMenu.separatorTitle, "+ Add current dir",
                "* Configure…"
            ]
        )
    }

    /// A list stored as JSON reads back the same.
    @Test
    internal func storedAsJSONAndReadBack() throws {
        let data = try JSONEncoder().encode(sample())
        #expect(try JSONDecoder().decode(Hotlist.self, from: data) == sample())
    }

    /// What an entry's command means: a folder to go to (focused on with `/:`), a command with its argument, or
    /// nothing.
    @Test
    internal func actions() {
        #expect(HotlistAction("cd /Users/x/dir") == .changeDirectory(path: "/Users/x/dir", focusingOnIt: false))
        #expect(HotlistAction("CD  \"/with space\"") == .changeDirectory(path: "/with space", focusingOnIt: false))
        #expect(HotlistAction("cd /Dir/Focusme/:") == .changeDirectory(path: "/Dir/Focusme", focusingOnIt: true))
        #expect(HotlistAction("/plain/path") == .changeDirectory(path: "/plain/path", focusingOnIt: false))
        #expect(HotlistAction("cm_GoToRoot") == .command("cm_GoToRoot", .nothing))
        #expect(HotlistAction("cm_SrcActivateTab 2") == .command("cm_SrcActivateTab", .index(2)))
        #expect(HotlistAction("afm_Something some text") == .command("afm_Something", .text("some text")))
        #expect(HotlistAction("   ") == .nothing)
        #expect(HotlistAction.targetPath("cd /backup") == "/backup" && HotlistAction.targetPath("/backup") == "/backup")
        #expect(HotlistAction.targetPath("") == nil && HotlistAction.targetPath("cm_GoToRoot") == nil)
    }

    /// The menu marks the entry of the current folder and the submenus that hold it, and offers to add or remove it.
    @Test
    internal func menuMarksTheCurrentDirectoryAndTheSubmenusHoldingIt() {
        let list = sample()
        let top = HotlistMenu(list, offersFavorites: true) { $0.command == "cd /old" }
        #expect(
            top.titles == [
                "    Work", "✓ Projects  ▸", HotlistMenu.separatorTitle, "    ?Secret", HotlistMenu.separatorTitle,
                "    Favorites  ▸", "+ Add current dir", "* Configure…"
            ]
        )
        #expect(top.selected == 1 && top.rows[1].action == .open([1]) && top.rows[5].action == .openFavorites)
        let inner = HotlistMenu(list, at: [1, 1], offersFavorites: true) { $0.command == "cd /old" }
        #expect(inner.titles == ["✓ Legacy", HotlistMenu.separatorTitle, "− Remove current dir", "* Configure…"])
        #expect(inner.rows[2].action == .removeCurrent([1, 1, 0]))
        #expect(HotlistMenu(Hotlist()) { _ in false }.titles == ["+ Add current dir", "* Configure…"])
        let places = HotlistMenu(places: MacFavorites.entries(home: URL(fileURLWithPath: "/Users/x"))) { entry in
            entry.command == "cd /Users/x/Desktop"
        }
        #expect(places.titles.prefix(3) == ["    Home", "    Applications", "✓ Desktop"] && places.selected == 2)
    }

    /// The editor's list indents the entries of submenus.
    @Test
    internal func editorListIndentsSubmenus() {
        #expect(
            sample().rows.map(HotlistEditorWindowController.title(of:))
                == [
                    "&Work", "▾ Projects", "      App", "      ▾ Old", "            Legacy", HotlistMenu.separatorTitle,
                    "?Secret"
                ]
        )
    }
}
