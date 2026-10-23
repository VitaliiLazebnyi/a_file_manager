import AFMKernel

/// The commands of this plugin that the kernel does not name itself (spec 03 › Folder tabs).
extension CommandID {
    /// Opens a copy of the active tab without showing it.
    internal static let newTabInBackground: CommandID = "cm_OpenNewTabBg"
    /// Opens a tab of the source panel's folder in the other panel and shows it.
    internal static let newTabInOtherPanel: CommandID = "cm_OpenNewTabOther"
    /// Opens a tab of the source panel's folder in the other panel without showing it.
    internal static let newTabInBackgroundInOtherPanel: CommandID = "cm_OpenNewTabBgOther"
    /// Opens the folder under the cursor in a new tab of the other panel.
    internal static let openInNewTabInOtherPanel: CommandID = "cm_OpenDirInNewTabOther"
    /// Closes every tab but the active one and the locked ones.
    internal static let closeAllTabs: CommandID = "cm_CloseAllTabs"
    /// Closes the tabs that show a folder an earlier tab already shows.
    internal static let closeDuplicateTabs: CommandID = "cm_CloseDuplicateTabs"
    /// Locks or unlocks the active tab.
    internal static let toggleTabLock: CommandID = "cm_ToggleLockCurrentTab"
    /// Unlocks the active tab.
    internal static let unlockTab: CommandID = "cm_SetTabOptionNormal"
    /// Locks the active tab.
    internal static let lockTab: CommandID = "cm_SetTabOptionPathLocked"
    /// Unlocks every tab of the source panel.
    internal static let unlockAllTabs: CommandID = "cm_SetAllTabsOptionNormal"
    /// Locks every tab of the source panel.
    internal static let lockAllTabs: CommandID = "cm_SetAllTabsOptionPathLocked"
    /// Names the active tab, and locks or unlocks it.
    ///
    /// `.text`: the new name (empty for the folder's name); without, the user is asked.
    internal static let renameTab: CommandID = "cm_RenameTab"
    /// Moves the active tab one place to the left.
    internal static let moveTabLeft: CommandID = "cm_MoveTabLeft"
    /// Moves the active tab one place to the right.
    internal static let moveTabRight: CommandID = "cm_MoveTabRight"
    /// Exchanges the tabs of the two panels.
    internal static let exchangeWithTabs: CommandID = "cm_ExchangeWithTabs"
    /// Lists the tabs of the source panel to pick one.
    internal static let sourceTabsList: CommandID = "cm_SrcTabsList"
    /// Lists the tabs of the target panel to pick one.
    internal static let targetTabsList: CommandID = "cm_TrgTabsList"
    /// Lists the tabs of the left panel to pick one.
    internal static let leftTabsList: CommandID = "cm_LeftTabsList"
    /// Lists the tabs of the right panel to pick one.
    internal static let rightTabsList: CommandID = "cm_RightTabsList"
    /// Opens a copy of the active tab beside it and shows it.
    internal static let duplicateTab: CommandID = "afm_DuplicateTab"
    /// Opens a copy of the active tab in the other panel.
    internal static let copyTabToOtherPanel: CommandID = "afm_CopyTabToOtherPanel"
    /// Moves the active tab to the other panel.
    internal static let moveTabToOtherPanel: CommandID = "afm_MoveTabToOtherPanel"
    /// Brings back the tab closed last.
    internal static let reopenClosedTab: CommandID = "afm_ReopenClosedTab"
    /// Lists the closed tabs to bring one back.
    internal static let recentlyClosedTabs: CommandID = "afm_RecentlyClosedTabs"
    /// Saves the source panel's tabs to a tab file (03 › Tab files and storage).
    ///
    /// The commands with parameters of the specification: `.location` or `.text` is the tab
    /// file; without, the user is asked for it.
    internal static let saveTabs: CommandID = "SAVETABS"
    /// Saves the tabs of both panels to a tab file.
    internal static let saveTabsOfBothSides: CommandID = "SAVETABS2"
    /// Loads a tab file in place of the panels' tabs.
    internal static let openTabs: CommandID = "OPENTABS"
    /// Loads a tab file beside the panels' tabs.
    internal static let appendTabs: CommandID = "APPENDTABS"

    /// `cm_SrcActivateTab1`…`10` and the `Trg`, `Left` and `Right` variants.
    internal static func activateTab(_ side: String, _ number: Int) -> CommandID {
        CommandID(rawValue: "cm_\(side)ActivateTab\(number)")
    }
}
