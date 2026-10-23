import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FolderTabsPlugin

/// The folder tab commands on a bench with two panels (spec 03 › Folder tabs).
@MainActor
@Suite
internal struct FolderTabCommands {
    /// The folders the panels show: `/A` with two folders and a file, `/B` with a file.
    internal let memory = MemoryFileSystem()
    /// The settings the plugin reads its options from.
    internal let settings = MemorySettings()
    /// A kernel with the folder tabs plugin, left in `/A`, right in `/B`.
    internal let bench: TestBench

    /// The bench's commands.
    internal var commands: CommandRegistry { bench.commands }
    /// The left panel, the source.
    internal var left: FakePanel { bench.left }
    /// The right panel, the target.
    internal var right: FakePanel { bench.right }
    /// The scripted answers to the plugin's questions.
    internal var interaction: ScriptedInteraction { bench.interaction }

    /// Fills the memory file system and starts the bench.
    internal init() {
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

    /// The paths of a panel's tabs, in their order.
    internal func paths(_ panel: FakePanel) -> [String] { panel.tabs.tabs.map(\.directory.path) }

    /// The specification's keys are bound without a clash, with a page of three options.
    @Test
    internal func registersTheSpecificationsKeysAndAPreferencePage() {
        let keys = bench.kernel.keyBindings
        #expect(keys.command(for: Shortcut(.character("t"), .control)) == .newTab)
        #expect(keys.command(for: Shortcut(.character("t"), [.control, .shift])) == "cm_OpenNewTabBg")
        #expect(keys.command(for: Shortcut(.upArrow, .control)) == .openInNewTab)
        #expect(keys.command(for: Shortcut(.upArrow, [.control, .shift])) == "cm_OpenDirInNewTabOther")
        #expect(keys.command(for: Shortcut(.character("w"), [.control, .shift])) == "cm_CloseAllTabs")
        #expect(keys.command(for: Shortcut(.character("a"), [.control, .shift])) == "cm_SrcTabsList")
        #expect(bench.kernel.keyClashes.isEmpty)
        #expect(bench.kernel.preferences.pages.first { $0.title == "Folder Tabs" }?.preferences.count == 3)
        let inMenus = bench.kernel.menus.menus.flatMap(\.items).compactMap(\.self)
        #expect(
            inMenus.allSatisfy { commands[$0] != nil } && inMenus.contains("SAVETABS")
                && inMenus.contains("afm_ReopenClosedTab")
        )
    }

    /// New tabs open in the background and in the other panel, with the folder under the cursor.
    @Test
    internal func opensTabsInTheBackgroundAndInTheOtherPanel() {
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

    /// The options open new tabs next to the active one and in the foreground.
    @Test
    internal func optionsDecideWhereAndHowNewTabsOpen() {
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

    /// Close All Other Tabs asks first, unless switched off, and leaves the locked tabs.
    @Test
    internal func closesAllOtherTabsAfterAsking() {
        for folder in ["docs", "pics"] { left.tabs.openTab(showing: memory.url("/A/" + folder), activate: false) }
        left.tabs.tabs[2].isLocked = true
        left.tabs.openTab(showing: memory.url("/B"), activate: true)
        interaction.choiceAnswers = [1]
        commands.perform("cm_CloseAllTabs")
        #expect(left.tabs.count == 4 && interaction.log.last?.hasPrefix("choose: Close all tabs?") == true)
        interaction.choiceAnswers = [0]
        commands.perform("cm_CloseAllTabs")
        #expect(paths(left) == ["/A/pics", "/B"] && left.tabs.activeIndex == 1)
        // Nothing left to close: no question.
        let asked = interaction.log.count
        commands.perform("cm_CloseAllTabs")
        #expect(interaction.log.count == asked)
        settings.set(false, forKey: FolderTabsPlugin.confirmCloseAllKey)
        left.tabs.openTab(showing: memory.url("/A"), activate: false)
        commands.perform("cm_CloseAllTabs")
        #expect(paths(left) == ["/A/pics", "/B"] && interaction.log.count == asked)
    }

    /// Close Duplicate Tabs keeps the active tab of each folder.
    @Test
    internal func closesDuplicatesKeepingTheActiveTab() {
        for path in ["/A/docs", "/A", "/A/docs", "/A/docs/", "/B"] {
            left.tabs.openTab(showing: memory.url(path), activate: false)
        }
        left.tabs.activate(3)
        commands.perform("cm_CloseDuplicateTabs")
        #expect(paths(left) == ["/A", "/A/docs", "/B"] && left.tabs.activeIndex == 1)
    }

    /// Closed tabs come back where they were, one by one or from the list.
    @Test
    internal func reopensClosedTabsWhereTheyWere() {
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
        interaction.formAnswers = [.accept]
        commands.perform("afm_RecentlyClosedTabs")
        #expect(
            paths(left) == ["/A", "/A/docs", "/A/pics"] && left.tabs.title(at: 1) == "Papers"
                && left.tabs.activeIndex == 1
        )
        #expect(!commands.isEnabled("afm_ReopenClosedTab"))
        // The right panel has a history of its own.
        #expect(!right.tabs.closeTab(at: 0))
    }

    /// Tabs are renamed and locked through the dialog, a parameter and the lock commands.
    @Test
    internal func renamesAndLocksTabs() {
        left.tabs.openTab(showing: memory.url("/A/docs"), activate: true)
        interaction.formAnswers = [.values(["name": .text("Papers"), "locked": .flag(true)])]
        commands.perform("cm_RenameTab")
        #expect(left.tabs.title(at: 1) == "*Papers" && left.model.isLocked)
        #expect(commands.isChecked("cm_ToggleLockCurrentTab"))
        // A locked tab is not closed.
        commands.perform(.closeTab)
        #expect(left.tabs.count == 2)
        // The dialog proposes the current name without the lock mark.
        interaction.formAnswers = [.values(["name": .text(""), "locked": .flag(false)])]
        commands.perform("cm_RenameTab")
        #expect(interaction.forms.last?.first?.initialValue == .text("Papers"))
        #expect(left.tabs.title(at: 1) == "docs" && !left.model.isLocked)
        interaction.formAnswers = [.accept]
        commands.perform("cm_RenameTab")
        #expect(left.model.customTitle == nil)
        commands.perform("cm_RenameTab", .text("Direct"))
        #expect(left.tabs.title(at: 1) == "Direct")
        commands.perform("cm_ToggleLockCurrentTab")
        commands.perform("cm_SetAllTabsOptionPathLocked")
        #expect(left.tabs.tabs.map(\.isLocked) == [true, true])
        commands.perform("cm_SetTabOptionNormal")
        #expect(left.tabs.tabs.map(\.isLocked) == [true, false])
        commands.perform("cm_SetAllTabsOptionNormal")
        commands.perform("cm_SetTabOptionPathLocked")
        #expect(left.tabs.tabs.map(\.isLocked) == [false, true])
    }

    /// Tabs are activated by number on each side, and from the list of open tabs.
    @Test
    internal func activatesTabsByNumberAndFromTheList() {
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
        interaction.formAnswers = [.values(["row": .index(2)])]
        commands.perform("cm_SrcTabsList")
        #expect(left.tabs.activeIndex == 2)
        guard case .list(let rows, let selected)? = interaction.forms.last?.first?.kind else {
            Issue.record("the tab list is not a list")
            return
        }
        #expect(rows.count == 3 && rows[1].hasPrefix("docs") && rows[1].hasSuffix("mem:/A/docs") && selected == 1)
        commands.perform("cm_SrcTabsList")
        #expect(left.tabs.activeIndex == 2)
    }

    /// Tabs move left and right, are duplicated, and are copied or moved to the other panel.
    @Test
    internal func movesTabsWithinAndBetweenThePanels() {
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

    /// Exchange Directories and Tabs swaps the panels' tabs with their options.
    @Test
    internal func exchangesThePanelsWithAllTheirTabs() {
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
}
