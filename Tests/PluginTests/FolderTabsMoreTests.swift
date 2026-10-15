import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FolderTabsPlugin

@Suite struct TabFiles {
    let memory = MemoryFileSystem()

    func read(_ text: String) -> TabFile? {
        TabFile(text: text) { memory.location(from: $0) }
    }

    @Test func writesAndReadsBothSides() {
        let active = PanelTabs.State(
            tabs: [
                .init(location: memory.url("/A"), title: "Work", locked: true),
                .init(
                    location: memory.url("/A/my docs"),
                    order: ListOrder(key: .date, descending: true),
                    showHidden: true
                )
            ],
            active: 1
        )
        let inactive = PanelTabs.State(tabs: [.init(location: memory.url("/B"))], active: 0)
        let text = TabFile(active: active, inactive: inactive).text(displayPath: memory.displayPath)
        #expect(
            text == """
                [activetabs]
                0_path=mem:/A
                0_caption=Work
                0_options=1|0|0|0|0|1|0
                1_path=mem:/A/my docs
                1_options=1|3|1|0|0|0|1
                activetab=1

                [inactivetabs]
                0_path=mem:/B
                0_options=1|0|0|0|0|0|0
                activetab=0

                """
        )
        #expect(read(text) == TabFile(active: active, inactive: inactive))
        #expect(read(TabFile(active: inactive).text(displayPath: memory.displayPath)) == TabFile(active: inactive))
    }

    @Test func readsHandWrittenAndDamagedFiles() throws {
        let file = try #require(
            read(
                "; my tabs\r\n[ActiveTabs]\r\n3_path=mem:/C\r\n1_path=mem:/A\r\n2_path=elsewhere\r\nactivetab=3\r\nunknown=1\r\n"
            )
        )
        #expect(file.active.tabs.map(\.location) == [memory.url("/A").absoluteString, memory.url("/C").absoluteString])
        #expect(file.active.active == 1 && file.inactive == nil)
        #expect(
            file.active.tabs[0].title == nil && !file.active.tabs[0].locked && !file.active.tabs[0].showHidden
        )
        #expect(read("") == nil && read("[activetabs]\nactivetab=0\n") == nil)
        // A file with only the other side's section still gives tabs.
        #expect(read("[inactivetabs]\n0_path=mem:/B\n")?.active.tabs.count == 1)
    }
}

@MainActor @Suite struct FolderTabCommands {
    let memory = MemoryFileSystem()
    let settings = MemorySettings()
    let bench: TestBench

    var commands: CommandRegistry { bench.commands }
    var left: FakePanel { bench.left }
    var right: FakePanel { bench.right }
    var ui: ScriptedInteraction { bench.interaction }

    init() {
        memory.addFile("/A/one.txt", "1")
        memory.addFile("/A/docs/in.txt", "inside")
        memory.addFile("/A/pics/cat.jpg", "meow")
        memory.addFile("/B/other.txt", "o")
        bench = TestBench(
            plugins: [FolderTabsPlugin()],
            fileSystems: [memory],
            left: memory.url("/A"),
            right: memory.url("/B"),
            settings: settings
        )
    }

    func paths(_ panel: FakePanel) -> [String] { panel.tabs.tabs.map(\.directory.path) }

    @Test func registersTheSpecificationsKeysAndAPreferencePage() {
        let keys = bench.kernel.keyBindings
        #expect(keys.command(for: Shortcut(.character("t"), .control)) == .newTab)
        #expect(keys.command(for: Shortcut(.character("t"), [.control, .shift])) == "cm_OpenNewTabBg")
        #expect(keys.command(for: Shortcut(.upArrow, .control)) == .openInNewTab)
        #expect(keys.command(for: Shortcut(.upArrow, [.control, .shift])) == "cm_OpenDirInNewTabOther")
        #expect(keys.command(for: Shortcut(.character("w"), [.control, .shift])) == "cm_CloseAllTabs")
        #expect(keys.command(for: Shortcut(.character("a"), [.control, .shift])) == "cm_SrcTabsList")
        #expect(bench.kernel.keyClashes.isEmpty)
        #expect(bench.kernel.preferences.pages.first { $0.title == "Folder Tabs" }?.preferences.count == 3)
        let inMenus = bench.kernel.menus.menus.flatMap(\.items).compactMap { $0 }
        #expect(
            inMenus.allSatisfy { commands[$0] != nil } && inMenus.contains("SAVETABS")
                && inMenus.contains("afm_ReopenClosedTab")
        )
    }

    @Test func opensTabsInTheBackgroundAndInTheOtherPanel() {
        commands.perform("cm_OpenNewTabBg")
        #expect(paths(left) == ["/A", "/A"] && left.tabs.activeIndex == 0)
        left.moveCursor(toName: "docs")
        commands.perform("cm_OpenDirInNewTabOther")
        #expect(paths(right) == ["/B", "/A/docs"] && right.tabs.activeIndex == 1 && right.names == ["in.txt"])
        // Not on a folder: the current directory goes to the other panel.
        left.moveCursor(toName: "one.txt")
        commands.perform("cm_OpenDirInNewTabOther")
        #expect(paths(right) == ["/B", "/A/docs", "/A"])
        commands.perform("cm_OpenNewTabOther")
        commands.perform("cm_OpenNewTabBgOther")
        #expect(paths(right) == ["/B", "/A/docs", "/A", "/A", "/A"] && right.tabs.activeIndex == 3)
        #expect(left.tabs.count == 2)
    }

    @Test func optionsDecideWhereAndHowNewTabsOpen() {
        left.moveCursor(toName: "docs")
        commands.perform(.openInNewTab)
        commands.perform(.openInNewTab)
        #expect(paths(left) == ["/A", "/A/docs", "/A/docs"] && left.tabs.activeIndex == 0)
        settings.set(true, forKey: FolderTabsPlugin.nearCurrentKey)
        left.moveCursor(toName: "pics")
        commands.perform(.openInNewTab)
        #expect(paths(left) == ["/A", "/A/pics", "/A/docs", "/A/docs"] && left.tabs.activeIndex == 0)
        settings.set(true, forKey: FolderTabsPlugin.foregroundKey)
        commands.perform(.openInNewTab)
        #expect(left.tabs.activeIndex == 1 && left.names == ["cat.jpg"])
        commands.perform(.newTab)
        #expect(
            paths(left) == ["/A", "/A/pics", "/A/pics", "/A/pics", "/A/docs", "/A/docs"] && left.tabs.activeIndex == 2
        )
    }

    @Test func closesAllOtherTabsAfterAsking() {
        for folder in ["docs", "pics"] { left.tabs.openTab(showing: memory.url("/A/" + folder), activate: false) }
        left.tabs.tabs[2].isLocked = true
        left.tabs.openTab(showing: memory.url("/B"), activate: true)
        ui.choiceAnswers = [1]
        commands.perform("cm_CloseAllTabs")
        #expect(left.tabs.count == 4 && ui.log.last?.hasPrefix("choose: Close all tabs?") == true)
        ui.choiceAnswers = [0]
        commands.perform("cm_CloseAllTabs")
        #expect(paths(left) == ["/A/pics", "/B"] && left.tabs.activeIndex == 1)
        // Nothing left to close: no question.
        let asked = ui.log.count
        commands.perform("cm_CloseAllTabs")
        #expect(ui.log.count == asked)
        settings.set(false, forKey: FolderTabsPlugin.confirmCloseAllKey)
        left.tabs.openTab(showing: memory.url("/A"), activate: false)
        commands.perform("cm_CloseAllTabs")
        #expect(paths(left) == ["/A/pics", "/B"] && ui.log.count == asked)
    }

    @Test func closesDuplicatesKeepingTheActiveTab() {
        for path in ["/A/docs", "/A", "/A/docs", "/A/docs/", "/B"] {
            left.tabs.openTab(showing: memory.url(path), activate: false)
        }
        left.tabs.activate(3)
        commands.perform("cm_CloseDuplicateTabs")
        #expect(paths(left) == ["/A", "/A/docs", "/B"] && left.tabs.activeIndex == 1)
    }

    @Test func reopensClosedTabsWhereTheyWere() {
        #expect(!commands.isEnabled("afm_ReopenClosedTab"))
        left.tabs.openTab(showing: memory.url("/A/docs"), activate: false)
        left.tabs.openTab(showing: memory.url("/A/pics"), activate: false)
        left.tabs.tabs[1].customTitle = "Papers"
        commands.perform(.closeTab, .index(1))
        commands.perform(.closeTab, .index(1))
        #expect(
            paths(left) == ["/A"] && commands.isEnabled("afm_ReopenClosedTab")
                && !commands.isEnabled("afm_ReopenClosedTab") == false
        )
        commands.perform("afm_ReopenClosedTab")
        #expect(paths(left) == ["/A", "/A/pics"] && left.tabs.activeIndex == 1 && left.names == ["cat.jpg"])
        ui.formAnswers = [.accept]
        commands.perform("afm_RecentlyClosedTabs")
        #expect(
            paths(left) == ["/A", "/A/docs", "/A/pics"] && left.tabs.title(at: 1) == "Papers"
                && left.tabs.activeIndex == 1
        )
        #expect(!commands.isEnabled("afm_ReopenClosedTab"))
        // The right panel has a history of its own.
        #expect(!right.tabs.closeTab(at: 0))
    }

    @Test func renamesAndLocksTabs() {
        left.tabs.openTab(showing: memory.url("/A/docs"), activate: true)
        ui.formAnswers = [.values(["name": .text("Papers"), "locked": .flag(true)])]
        commands.perform("cm_RenameTab")
        #expect(left.tabs.title(at: 1) == "*Papers" && left.model.isLocked)
        #expect(commands.isChecked("cm_ToggleLockCurrentTab"))
        // A locked tab is not closed.
        commands.perform(.closeTab)
        #expect(left.tabs.count == 2)
        // The dialog proposes the current name without the lock mark.
        ui.formAnswers = [.values(["name": .text(""), "locked": .flag(false)])]
        commands.perform("cm_RenameTab")
        #expect(ui.forms.last?.first?.initialValue == .text("Papers"))
        #expect(left.tabs.title(at: 1) == "docs" && !left.model.isLocked)
        ui.formAnswers = [.accept]
        commands.perform("cm_RenameTab")
        #expect(left.model.customTitle == nil)
        commands.perform("cm_RenameTab", .text("Direct"))
        #expect(left.tabs.title(at: 1) == "Direct")
        commands.perform("cm_ToggleLockCurrentTab")
        commands.perform("cm_SetAllTabsOptionPathLocked")
        #expect(left.tabs.tabs.allSatisfy { $0.isLocked })
        commands.perform("cm_SetTabOptionNormal")
        #expect(left.tabs.tabs.map { $0.isLocked } == [true, false])
        commands.perform("cm_SetAllTabsOptionNormal")
        commands.perform("cm_SetTabOptionPathLocked")
        #expect(left.tabs.tabs.map { $0.isLocked } == [false, true])
    }

    @Test func activatesTabsByNumberAndFromTheList() {
        for folder in ["docs", "pics"] { left.tabs.openTab(showing: memory.url("/A/" + folder), activate: false) }
        commands.perform("cm_SrcActivateTab3")
        #expect(left.tabs.activeIndex == 2 && left.names == ["cat.jpg"])
        commands.perform("cm_LeftActivateTab1")
        #expect(left.tabs.activeIndex == 0)
        commands.perform("cm_SrcActivateTab1", .index(2))
        #expect(left.tabs.activeIndex == 1)
        commands.perform("cm_SrcActivateTab9")
        #expect(left.tabs.activeIndex == 1)
        right.tabs.openTab(showing: memory.url("/A"), activate: false)
        commands.perform("cm_TrgActivateTab2")
        commands.perform("cm_RightActivateTab2")
        #expect(right.tabs.activeIndex == 1 && bench.panels.source === left)
        ui.formAnswers = [.values(["row": .index(2)])]
        commands.perform("cm_SrcTabsList")
        #expect(left.tabs.activeIndex == 2)
        guard case .list(let rows, let selected)? = ui.forms.last?.first?.kind else {
            Issue.record("the tab list is not a list")
            return
        }
        #expect(rows.count == 3 && rows[1].hasPrefix("docs") && rows[1].hasSuffix("mem:/A/docs") && selected == 1)
        commands.perform("cm_SrcTabsList")
        #expect(left.tabs.activeIndex == 2)
    }

    @Test func movesTabsWithinAndBetweenThePanels() {
        left.tabs.openTab(showing: memory.url("/A/docs"), activate: true)
        left.model.customTitle = "Papers"
        commands.perform("cm_MoveTabLeft")
        #expect(
            paths(left) == ["/A/docs", "/A"] && left.tabs.activeIndex == 0 && !commands.isEnabled("cm_MoveTabLeft")
        )
        commands.perform("cm_MoveTabRight")
        #expect(
            paths(left) == ["/A", "/A/docs"] && left.tabs.activeIndex == 1 && !commands.isEnabled("cm_MoveTabRight")
        )
        commands.perform("afm_DuplicateTab")
        #expect(paths(left) == ["/A", "/A/docs", "/A/docs"] && left.tabs.activeIndex == 2 && left.names == ["in.txt"])
        left.tabs.activate(1)
        commands.perform("afm_CopyTabToOtherPanel")
        #expect(
            paths(right) == ["/B", "/A/docs"] && right.tabs.activeIndex == 1 && right.tabs.title(at: 1) == "Papers"
                && left.tabs.count == 3
        )
        commands.perform("afm_MoveTabToOtherPanel")
        #expect(
            paths(left) == ["/A", "/A/docs"] && paths(right) == ["/B", "/A/docs", "/A/docs"]
                && right.tabs.activeIndex == 2
        )
        left.tabs.closeTab(at: 1)
        #expect(!commands.isEnabled("afm_MoveTabToOtherPanel"))
    }

    @Test func exchangesThePanelsWithAllTheirTabs() {
        left.tabs.openTab(showing: memory.url("/A/docs"), activate: true)
        left.model.isLocked = true
        left.tabs.tabs[0].setSort(ListOrder(key: .size, descending: true))
        commands.perform("cm_ExchangeWithTabs")
        #expect(paths(left) == ["/B"] && left.names == ["other.txt"])
        #expect(
            paths(right) == ["/A", "/A/docs"] && right.tabs.activeIndex == 1 && right.model.isLocked
                && right.names == ["in.txt"]
        )
        #expect(right.tabs.tabs[0].sort == ListOrder(key: .size, descending: true))
    }

    @Test func savesAndLoadsTabFiles() throws {
        left.tabs.openTab(showing: memory.url("/A/docs"), activate: true)
        left.model.customTitle = "Papers"
        ui.promptAnswers = [.text("mem:/B/mine")]
        commands.perform("SAVETABS")
        #expect(ui.log.contains("prompt: Save tabs to file: [mem:/A/docs/tabs.tab]"))
        let saved = try #require(memory.contents("/B/mine.tab"))
        #expect(
            saved.hasPrefix("[activetabs]\n0_path=mem:/A\n") && saved.contains("1_caption=Papers")
                && !saved.contains("[inactivetabs]")
        )
        #expect(right.names == ["mine.tab", "other.txt"] && bench.jobService.titles == ["Save tabs"])

        // Appending keeps the tabs and the active one; replacing takes the file's.
        right.focus()
        commands.perform("APPENDTABS", .location(memory.url("/B/mine.tab")))
        #expect(
            paths(right) == ["/B", "/A", "/A/docs"] && right.tabs.activeIndex == 0
                && right.tabs.title(at: 2) == "Papers"
        )
        right.tabs.tabs[0].isLocked = true
        commands.perform("OPENTABS", .text("mine.tab"))
        #expect(paths(right) == ["/A", "/A/docs"] && right.tabs.activeIndex == 1 && right.names == ["in.txt"])

        // Saving again asks before the file is replaced.
        ui.choiceAnswers = [1]
        commands.perform("SAVETABS2", .location(memory.url("/B/mine.tab")))
        #expect(memory.contents("/B/mine.tab") == saved)
        ui.choiceAnswers = [0]
        commands.perform("SAVETABS2", .location(memory.url("/B/mine.tab")))
        let both = try #require(memory.contents("/B/mine.tab"))
        #expect(both.contains("[inactivetabs]"))

        // A file with both sides fills both panels, its first section going to the source.
        left.focus()
        left.tabs.closeTab(at: 1)
        commands.perform("OPENTABS", .location(memory.url("/B/mine.tab")))
        #expect(paths(left) == ["/A", "/A/docs"] && paths(right) == ["/A", "/A/docs"])
    }

    @Test func aMissingOrEmptyTabFileIsReported() {
        commands.perform("OPENTABS", .location(memory.url("/B/none.tab")))
        #expect(ui.log.last == "inform: The tabs could not be loaded." && left.tabs.count == 1)
        commands.perform("OPENTABS", .location(memory.url("/B/other.txt")))
        #expect(ui.log.last == "inform: The file holds no tabs." && left.tabs.count == 1)
        ui.promptAnswers = [.cancel]
        commands.perform("SAVETABS")
        #expect(bench.jobService.titles == ["Load tabs", "Load tabs"])
    }
}
