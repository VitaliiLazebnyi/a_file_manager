public import AFMKernel

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
    /// F5: copies the marked items, or the one under the cursor, to the other panel.
    ///
    /// Takes nothing.
    public static let copy: CommandID = "cm_Copy"
    /// Copies the item under the cursor within its own folder, under a new name.
    public static let copySamePanel: CommandID = "cm_CopySamepanel"
    /// F6: moves or renames the marked items, or the one under the cursor.
    ///
    /// Takes nothing.
    public static let renameMove: CommandID = "cm_RenMov"
    /// `.text`: the new name of the item under the cursor; without, the name is edited in place.
    public static let renameOnly: CommandID = "cm_RenameOnly"
    /// F7: makes a new folder in the source panel, asking for its name.
    ///
    /// Takes nothing.
    public static let makeDirectory: CommandID = "cm_MkDir"
    /// Makes a new text file in the source panel and opens it in the editor.
    public static let newTextFile: CommandID = "cm_EditNewFile"
    /// F8: deletes the marked items, or the one under the cursor, into the Trash where there is one.
    public static let delete: CommandID = "cm_Delete"
    /// Deletes the marked items at once, without the Trash.
    public static let deleteDirectly: CommandID = "afm_DeleteDirectly"
    /// Opens the Find Files window for the source folder.
    ///
    /// Takes nothing.
    public static let searchFor: CommandID = "cm_SearchFor"
    /// Shows the item under the cursor in a Finder window.
    public static let revealInFinder: CommandID = "afm_RevealInFinder"

    // MARK: Clipboard
    /// Cmd+X: puts the marked items on the clipboard, to be moved where they are pasted.
    public static let cutToClipboard: CommandID = "cm_CutToClipboard"
    /// Cmd+C: puts the marked items on the clipboard, to be copied where they are pasted.
    public static let copyToClipboard: CommandID = "cm_CopyToClipboard"
    /// Cmd+V: copies or moves what is on the clipboard into the source folder.
    public static let pasteFromClipboard: CommandID = "cm_PasteFromClipboard"
    /// Puts the full paths of the marked items on the clipboard as text.
    public static let copyFullNames: CommandID = "cm_CopyFullNamesToClip"

    // MARK: Mark
    /// Marks the items whose names match a mask the user types.
    public static let selectGroup: CommandID = "cm_SpreadSelection"
    /// Unmarks the items whose names match a mask the user types.
    public static let unselectGroup: CommandID = "cm_ShrinkSelection"
    /// Marks every item of the source panel.
    public static let selectAll: CommandID = "cm_SelectAll"
    /// Unmarks every item of the source panel.
    public static let unselectAll: CommandID = "cm_ClearAll"
    /// Marks what was not marked and unmarks what was.
    public static let invertSelection: CommandID = "cm_ExchangeSelection"
    /// Marks again what was marked before the last command cleared it.
    public static let restoreSelection: CommandID = "cm_RestoreSelection"

    // MARK: Commands
    /// `.location`: the place to show in the source panel; `.text`: the same as the user would
    /// type it (spec 02 › Command line, `cd`).
    public static let changeDirectory: CommandID = "cd"
    /// Shows the folder the source panel showed before, as Back in a browser.
    public static let goBack: CommandID = "cm_GoToPreviousDir"
    /// Shows again the folder that Back left.
    public static let goForward: CommandID = "cm_GoToNextDir"
    /// Shows the folder above the one shown, with the cursor on the folder that was left.
    public static let goToParent: CommandID = "cm_GoToParent"
    /// Asks for a folder and shows it in the source panel.
    public static let goToDirectory: CommandID = "cm_GoToDir"
    /// Shows the top of the source panel's file system (the root of its disk or archive).
    public static let goToRoot: CommandID = "cm_GoToRoot"
    /// Shows the home folder in the source panel.
    public static let goHome: CommandID = "afm_GoHome"
    /// Lets the user edit the path of the source panel in place.
    public static let editPath: CommandID = "cm_EditPath"
    /// Shows the source panel's folder in the other panel as well.
    public static let targetEqualsSource: CommandID = "cm_MatchSrc"
    /// Swaps what the two panels show.
    public static let exchangePanels: CommandID = "cm_Exchange"
    /// Reads the source panel's folder again.
    public static let reread: CommandID = "cm_RereadSource"

    // MARK: Show
    /// Sorts the source panel by name.
    public static let sortByName: CommandID = "cm_SrcByName"
    /// Sorts the source panel by extension.
    public static let sortByExtension: CommandID = "cm_SrcByExt"
    /// Sorts the source panel by the date of last change.
    public static let sortByTime: CommandID = "cm_SrcByDateTime"
    /// Sorts the source panel by size.
    public static let sortBySize: CommandID = "cm_SrcBySize"
    /// Shows the source panel in the order the file system lists it.
    public static let unsorted: CommandID = "cm_SrcUnsorted"
    /// Turns the sort order of the source panel round.
    public static let reversedOrder: CommandID = "cm_SrcNegOrder"
    /// Shows or hides the hidden files in both panels.
    public static let showHidden: CommandID = "cm_SwitchHidSys"

    // MARK: Folder tabs
    /// Opens a new folder tab in the source panel, showing the same folder.
    public static let newTab: CommandID = "cm_OpenNewTab"
    /// Opens the folder under the cursor in a new tab.
    public static let openInNewTab: CommandID = "cm_OpenDirInNewTab"
    /// `.index`: the tab to close; without, the active tab.
    public static let closeTab: CommandID = "cm_CloseCurrentTab"
    /// Shows the next tab of the source panel.
    public static let nextTab: CommandID = "cm_SwitchToNextTab"
    /// Shows the previous tab of the source panel.
    public static let previousTab: CommandID = "cm_SwitchToPreviousTab"
    /// `.index`: the tab to show.
    public static let activateTab: CommandID = "cm_SrcActivateTab"

    // MARK: The file list itself (provided by the window shell)
    /// Makes the other panel the source.
    public static let focusTarget: CommandID = "cm_FocusTrg"
    /// Opens the volume list of the left panel.
    public static let leftVolumes: CommandID = "cm_LeftOpenDrives"
    /// Opens the volume list of the right panel.
    public static let rightVolumes: CommandID = "cm_RightOpenDrives"
    /// Puts the cursor on the first entry of the list.
    public static let cursorToFirstEntry: CommandID = "cm_GoToFirstEntry"
    /// Puts the cursor on the last entry of the list.
    public static let cursorToLastEntry: CommandID = "cm_GoToLast"
    /// Puts the cursor on the top line of the list, `[..]` where there is one.
    public static let cursorToTop: CommandID = "afm_CursorToTop"
    /// Moves the cursor up by one page of the list.
    public static let cursorPageUp: CommandID = "afm_CursorPageUp"
    /// Moves the cursor down by one page of the list.
    public static let cursorPageDown: CommandID = "afm_CursorPageDown"
    /// Toggles the item under the cursor and moves down (Insert).
    public static let toggleSelectionAndMoveDown: CommandID = "cm_Reverse"
    /// Toggles the mark of the item under the cursor and moves up.
    public static let toggleSelectionAndMoveUp: CommandID = "afm_ReverseUp"
    /// Toggles the item under the cursor; on a folder also calculates its size (Space).
    public static let toggleSelectionWithSize: CommandID = "afm_ToggleSelectionWithSize"
    /// Starts editing the name under the cursor in place.
    public static let editNameInPlace: CommandID = "afm_EditNameInPlace"
    /// Opens the quick-filter box of the source panel: the list shows only the names that
    /// contain what is typed.
    public static let quickFilter: CommandID = "cm_ShowQuickSearch"
    /// Shows the source panel in Brief view: names only, in columns.
    public static let viewBrief: CommandID = "cm_SrcShort"
    /// Shows the source panel in Full view: one row per item, with its details.
    public static let viewFull: CommandID = "cm_SrcLong"
    /// Shows the source panel as thumbnails.
    public static let viewThumbnails: CommandID = "cm_SrcThumbs"

    // MARK: The window (provided by the window shell)
    /// Puts the keyboard focus into the command line.
    public static let focusCommandLine: CommandID = "cm_FocusCmdLine"
    /// Shows or hides the button bar.
    public static let showButtonBar: CommandID = "cm_VisButtonbar"
    /// Shows or hides the command line.
    public static let showCommandLine: CommandID = "cm_VisCmdLine"
    /// Shows or hides the function-key bar.
    public static let showFunctionKeys: CommandID = "cm_VisKeyButtons"
    /// Shows or hides the volume buttons.
    public static let showDriveButtons: CommandID = "cm_VisDriveButtons"
    /// Puts the panels one above the other, or side by side again.
    public static let panelsStacked: CommandID = "cm_VerticalPanels"
    /// Gives both panels the same width.
    public static let panelsEqualWidth: CommandID = "cm_50Percent"

    // MARK: Names several plugins share
    /// `.text`: a line as typed on the command line, run in the source panel's folder (spec 02 › Command line).
    ///
    /// The shell's command line hands over what is neither `cd` nor the name of a command.
    public static let runCommandLine: CommandID = "afm_RunCommandLine"
    /// Shows the file under the cursor in the other panel and follows the cursor (Ctrl+Q).
    public static let quickView: CommandID = "cm_SrcQuickview"
    /// Opens the configuration dialog.
    public static let configuration: CommandID = "cm_Config"
    /// Packs the marked items into an archive.
    public static let packFiles: CommandID = "cm_PackFiles"
    /// Unpacks the marked archives.
    public static let unpackFiles: CommandID = "cm_UnpackFiles"
    /// Opens the Multi-Rename tool for the marked items.
    public static let multiRename: CommandID = "cm_MultiRenameFiles"
    /// Opens the window that compares and synchronizes the two panels' folders.
    public static let synchronizeDirectories: CommandID = "cm_FileSync"
    /// Compares the contents of two files side by side.
    public static let compareByContent: CommandID = "cm_CompareFilesByContent"
    /// Opens the list of the user's favourite folders.
    public static let directoryHotlist: CommandID = "cm_DirectoryHotlist"
    /// Opens the list of the folders the source panel showed.
    public static let directoryHistory: CommandID = "cm_DirectoryHistory"
    /// Shows every file below the source folder in one list.
    public static let branchView: CommandID = "cm_DirBranch"
    /// Opens the list of saved server connections.
    public static let ftpConnect: CommandID = "cm_FtpConnect"
    /// Opens the properties of the item under the cursor.
    public static let properties: CommandID = "cm_VersionInfo"
    /// Changes the dates and permissions of the marked items.
    public static let setAttributes: CommandID = "cm_SetAttrib"
    /// Works out how much space the marked items take, folders included.
    public static let occupiedSpace: CommandID = "cm_GetFileSpace"
}
