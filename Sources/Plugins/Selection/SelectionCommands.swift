public import AFMKernel
import Foundation

/// The names of the Mark commands that only this plugin uses (spec 17 › Command catalogue);
/// the ones other plugins and the shell refer to are in the shared vocabulary.
public enum SelectionCommands {
    // Select group / Unselect group, with a fixed choice of what they affect.
    /// Select group over files and folders, whatever the configuration says.
    public static let selectBoth: CommandID = "cm_SelectBoth"
    /// Select group over files only.
    public static let selectFiles: CommandID = "cm_SelectFiles"
    /// Select group over folders only.
    public static let selectFolders: CommandID = "cm_SelectFolders"
    /// Unselect group over files only.
    public static let clearFiles: CommandID = "cm_ClearFiles"
    /// Unselect group over folders only.
    public static let clearFolders: CommandID = "cm_ClearFolders"
    /// Unselect group over files, or files and folders, as configured (`MarkDirectories`).
    public static let clearAsConfigured: CommandID = "cm_ClearSelCfg"
    /// Select group with `*.ext` of the file under the cursor proposed.
    public static let selectGroupCurrentExtension: CommandID = "cm_SpreadSelectionCurrentExt"
    /// Select or unselect by a saved selection type or an earlier mask, chosen from a list.
    public static let selectFromList: CommandID = "afm_SelectFromList"
    /// Opens the dialog that defines, changes and removes the saved selection types.
    public static let defineSelectionType: CommandID = "afm_DefineSelectionType"

    // Select all / Unselect all / Invert. `.index`: 0 = all, n = every n-th line down from
    // the cursor, -n = upward.
    /// Select all, files and folders.
    public static let selectAllBoth: CommandID = "cm_SelectAllBoth"
    /// Select all, files only.
    public static let selectAllFiles: CommandID = "cm_SelectAllFiles"
    /// Select all, folders only.
    public static let selectAllFolders: CommandID = "cm_SelectAllFolders"
    /// Unselect all, files only.
    public static let clearAllFiles: CommandID = "cm_ClearAllFiles"
    /// Unselect all, folders only.
    public static let clearAllFolders: CommandID = "cm_ClearAllFolders"
    /// Unselect all over files, or files and folders, as configured.
    public static let clearAllAsConfigured: CommandID = "cm_ClearAllCfg"
    /// Inverts the selection of files and folders.
    public static let invertBoth: CommandID = "cm_ExchangeSelBoth"
    /// Inverts the selection of files only.
    public static let invertFiles: CommandID = "cm_ExchangeSelFiles"
    /// Inverts the selection of folders only.
    public static let invertFolders: CommandID = "cm_ExchangeSelFolders"
    /// The Shift variants of Num +, Ctrl+Num + and Num *: the choice of files or files and
    /// folders that is *not* configured (spec 03 › Selection, Keyboard).
    public static let selectGroupOtherChoice: CommandID = "afm_SelectGroupOtherChoice"
    /// Select all over the choice that is not configured.
    public static let selectAllOtherChoice: CommandID = "afm_SelectAllOtherChoice"
    /// Inverts the selection over the choice that is not configured.
    public static let invertOtherChoice: CommandID = "afm_InvertSelectionOtherChoice"

    // By the item under the cursor.
    /// Selects the entries with the extension of the one under the cursor.
    public static let selectCurrentExtension: CommandID = "cm_SelectCurrentExtension"
    /// Unselects the entries with the extension of the one under the cursor.
    public static let unselectCurrentExtension: CommandID = "cm_UnselectCurrentExtension"
    /// Selects the entries with the name, without extension, of the one under the cursor.
    public static let selectCurrentName: CommandID = "cm_SelectCurrentName"
    /// Unselects the entries with the name, without extension, of the one under the cursor.
    public static let unselectCurrentName: CommandID = "cm_UnselectCurrentName"
    /// Selects the entries with the whole name of the one under the cursor.
    public static let selectCurrentNameAndExtension: CommandID = "cm_SelectCurrentNameExt"
    /// Unselects the entries with the whole name of the one under the cursor.
    public static let unselectCurrentNameAndExtension: CommandID = "cm_UnselectCurrentNameExt"
    /// Selects the entries in the same folder as the one under the cursor (a branch view, a search result).
    public static let selectCurrentPath: CommandID = "cm_SelectCurrentPath"
    /// Unselects the entries in the same folder as the one under the cursor.
    public static let unselectCurrentPath: CommandID = "cm_UnselectCurrentPath"
    /// `.index`: how many items from the cursor on (default 1); the cursor moves past them.
    public static let select: CommandID = "cm_Select"
    /// Unselects items from the cursor on, with `.index` as for `select`.
    public static let unselect: CommandID = "cm_UnSelect"

    // Saving and loading.
    /// Remembers the selection of the panel for Restore selection.
    public static let saveSelection: CommandID = "cm_SaveSelection"
    /// `.text` or `.location`: the file to write; without, the name is asked for.
    public static let saveSelectionToFile: CommandID = "cm_SaveSelectionToFile"
    /// Save selection to file in Windows-1252; `.text` or `.location` as for `saveSelectionToFile`.
    public static let saveSelectionToFileANSI: CommandID = "cm_SaveSelectionToFileA"
    /// Save selection to file in UTF-16; `.text` or `.location` as for `saveSelectionToFile`.
    public static let saveSelectionToFileUnicode: CommandID = "cm_SaveSelectionToFileW"
    /// `.text` or `.location`: the file to read; without, the name is asked for.
    public static let loadSelectionFromFile: CommandID = "cm_LoadSelectionFromFile"
    /// Selects the entries whose names the text on the clipboard lists, one per line.
    public static let loadSelectionFromClipboard: CommandID = "cm_LoadSelectionFromClip"

    // Comparing the two panels. `.index` of the first two: 0 = missing, newer, or another
    // size at the same time; 1 = missing only; 2 = another size, or missing.
    /// Marks the files of each panel that differ from the other side, as `.index` chooses.
    public static let compareDirectories: CommandID = "cm_CompareDirs"
    /// The same, also marking the folders that the other side does not have.
    public static let compareDirectoriesWithSubdirectories: CommandID = "cm_CompareDirsWithSubdirs"
    /// Marks what is missing or newer on the other side and hides the files that are the same on both.
    public static let markNewerHideSame: CommandID = "cm_DirMatch"
}
