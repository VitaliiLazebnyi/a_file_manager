import AFMKernel
import Foundation

/// The command vocabulary shared by the plugins and the shell: the internal command names of
/// the specification (17 › Command catalogue), with what each expects as its argument.
/// `afm_` marks commands that only exist on the Mac. This is a list of names, not of features;
/// a name does nothing until a plugin registers it, and the kernel knows none of them.
extension CommandID {
    // MARK: Files
    /// Enter: goes into a folder, or opens a file through the kernel's openers.
    public static let open: CommandID = "cm_Return"
    /// `.location`: the file to view; without, the file under the cursor.
    public static let view: CommandID = "cm_List"
    /// `.location`: the file to edit; without, the file under the cursor.
    public static let edit: CommandID = "cm_Edit"
    public static let copy: CommandID = "cm_Copy"
    public static let copySamePanel: CommandID = "cm_CopySamepanel"
    public static let renameMove: CommandID = "cm_RenMov"
    /// `.text`: the new name of the item under the cursor; without, the name is edited in place.
    public static let renameOnly: CommandID = "cm_RenameOnly"
    public static let makeDirectory: CommandID = "cm_MkDir"
    public static let newTextFile: CommandID = "cm_EditNewFile"
    public static let delete: CommandID = "cm_Delete"
    public static let deleteDirectly: CommandID = "afm_DeleteDirectly"
    public static let searchFor: CommandID = "cm_SearchFor"
    public static let revealInFinder: CommandID = "afm_RevealInFinder"

    // MARK: Clipboard
    public static let cutToClipboard: CommandID = "cm_CutToClipboard"
    public static let copyToClipboard: CommandID = "cm_CopyToClipboard"
    public static let pasteFromClipboard: CommandID = "cm_PasteFromClipboard"
    public static let copyFullNames: CommandID = "cm_CopyFullNamesToClip"

    // MARK: Mark
    public static let selectGroup: CommandID = "cm_SpreadSelection"
    public static let unselectGroup: CommandID = "cm_ShrinkSelection"
    public static let selectAll: CommandID = "cm_SelectAll"
    public static let unselectAll: CommandID = "cm_ClearAll"
    public static let invertSelection: CommandID = "cm_ExchangeSelection"
    public static let restoreSelection: CommandID = "cm_RestoreSelection"

    // MARK: Commands
    /// `.location`: the place to show in the source panel; `.text`: the same as the user would
    /// type it (spec 02 › Command line, `cd`).
    public static let changeDirectory: CommandID = "cd"
    public static let goBack: CommandID = "cm_GoToPreviousDir"
    public static let goForward: CommandID = "cm_GoToNextDir"
    public static let goToParent: CommandID = "cm_GoToParent"
    public static let goToDirectory: CommandID = "cm_GoToDir"
    public static let goToRoot: CommandID = "cm_GoToRoot"
    public static let goHome: CommandID = "afm_GoHome"
    public static let editPath: CommandID = "cm_EditPath"
    public static let targetEqualsSource: CommandID = "cm_MatchSrc"
    public static let exchangePanels: CommandID = "cm_Exchange"
    public static let reread: CommandID = "cm_RereadSource"

    // MARK: Show
    public static let sortByName: CommandID = "cm_SrcByName"
    public static let sortByExtension: CommandID = "cm_SrcByExt"
    public static let sortByTime: CommandID = "cm_SrcByDateTime"
    public static let sortBySize: CommandID = "cm_SrcBySize"
    public static let unsorted: CommandID = "cm_SrcUnsorted"
    public static let reversedOrder: CommandID = "cm_SrcNegOrder"
    public static let showHidden: CommandID = "cm_SwitchHidSys"

    // MARK: Folder tabs
    public static let newTab: CommandID = "cm_OpenNewTab"
    public static let openInNewTab: CommandID = "cm_OpenDirInNewTab"
    /// `.index`: the tab to close; without, the active tab.
    public static let closeTab: CommandID = "cm_CloseCurrentTab"
    public static let nextTab: CommandID = "cm_SwitchToNextTab"
    public static let previousTab: CommandID = "cm_SwitchToPreviousTab"
    /// `.index`: the tab to show.
    public static let activateTab: CommandID = "cm_SrcActivateTab"

    // MARK: The file list itself (provided by the window shell)
    public static let focusTarget: CommandID = "cm_FocusTrg"
    public static let leftVolumes: CommandID = "cm_LeftOpenDrives"
    public static let rightVolumes: CommandID = "cm_RightOpenDrives"
    public static let cursorToFirstEntry: CommandID = "cm_GoToFirstEntry"
    public static let cursorToLastEntry: CommandID = "cm_GoToLast"
    public static let cursorToTop: CommandID = "afm_CursorToTop"
    public static let cursorPageUp: CommandID = "afm_CursorPageUp"
    public static let cursorPageDown: CommandID = "afm_CursorPageDown"
    /// Toggles the item under the cursor and moves down (Insert).
    public static let toggleSelectionAndMoveDown: CommandID = "cm_Reverse"
    public static let toggleSelectionAndMoveUp: CommandID = "afm_ReverseUp"
    /// Toggles the item under the cursor; on a folder also calculates its size (Space).
    public static let toggleSelectionWithSize: CommandID = "afm_ToggleSelectionWithSize"
    /// Starts editing the name under the cursor in place.
    public static let editNameInPlace: CommandID = "afm_EditNameInPlace"
    /// Opens the quick-filter box of the source panel: the list shows only the names that
    /// contain what is typed.
    public static let quickFilter: CommandID = "cm_ShowQuickSearch"
    public static let viewBrief: CommandID = "cm_SrcShort"
    public static let viewFull: CommandID = "cm_SrcLong"
    public static let viewThumbnails: CommandID = "cm_SrcThumbs"

    // MARK: The window (provided by the window shell)
    public static let focusCommandLine: CommandID = "cm_FocusCmdLine"
    public static let showButtonBar: CommandID = "cm_VisButtonbar"
    public static let showCommandLine: CommandID = "cm_VisCmdLine"
    public static let showFunctionKeys: CommandID = "cm_VisKeyButtons"
    public static let showDriveButtons: CommandID = "cm_VisDriveButtons"
    public static let panelsStacked: CommandID = "cm_VerticalPanels"
    public static let panelsEqualWidth: CommandID = "cm_50Percent"

    // MARK: Names several plugins share
    /// `.text`: a line as typed on the command line, run in the source panel's folder
    /// (spec 02 › Command line). The shell's command line hands over what is neither `cd` nor
    /// the name of a command.
    public static let runCommandLine: CommandID = "afm_RunCommandLine"
    /// Shows the file under the cursor in the other panel and follows the cursor (Ctrl+Q).
    public static let quickView: CommandID = "cm_SrcQuickview"
    public static let configuration: CommandID = "cm_Config"
    public static let packFiles: CommandID = "cm_PackFiles"
    public static let unpackFiles: CommandID = "cm_UnpackFiles"
    public static let multiRename: CommandID = "cm_MultiRenameFiles"
    public static let synchronizeDirectories: CommandID = "cm_FileSync"
    public static let compareByContent: CommandID = "cm_CompareFilesByContent"
    public static let directoryHotlist: CommandID = "cm_DirectoryHotlist"
    public static let directoryHistory: CommandID = "cm_DirectoryHistory"
    public static let branchView: CommandID = "cm_DirBranch"
    public static let ftpConnect: CommandID = "cm_FtpConnect"
    public static let properties: CommandID = "cm_VersionInfo"
    public static let setAttributes: CommandID = "cm_SetAttrib"
    public static let occupiedSpace: CommandID = "cm_GetFileSpace"
}
