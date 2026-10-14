public import AFMKernel
import Foundation

/// The names of the Mark commands that only this plugin uses (spec 17 › Command catalogue);
/// the ones other plugins and the shell refer to are in the shared vocabulary.
public enum SelectionCommands {
    // Select group / Unselect group, with a fixed choice of what they affect.
    public static let selectBoth: CommandID = "cm_SelectBoth"
    public static let selectFiles: CommandID = "cm_SelectFiles"
    public static let selectFolders: CommandID = "cm_SelectFolders"
    public static let clearFiles: CommandID = "cm_ClearFiles"
    public static let clearFolders: CommandID = "cm_ClearFolders"
    public static let clearAsConfigured: CommandID = "cm_ClearSelCfg"
    /// Select group with `*.ext` of the file under the cursor proposed.
    public static let selectGroupCurrentExtension: CommandID = "cm_SpreadSelectionCurrentExt"
    /// Select or unselect by a saved selection type or an earlier mask, chosen from a list.
    public static let selectFromList: CommandID = "afm_SelectFromList"
    public static let defineSelectionType: CommandID = "afm_DefineSelectionType"

    // Select all / Unselect all / Invert. `.index`: 0 = all, n = every n-th line down from
    // the cursor, -n = upward.
    public static let selectAllBoth: CommandID = "cm_SelectAllBoth"
    public static let selectAllFiles: CommandID = "cm_SelectAllFiles"
    public static let selectAllFolders: CommandID = "cm_SelectAllFolders"
    public static let clearAllFiles: CommandID = "cm_ClearAllFiles"
    public static let clearAllFolders: CommandID = "cm_ClearAllFolders"
    public static let clearAllAsConfigured: CommandID = "cm_ClearAllCfg"
    public static let invertBoth: CommandID = "cm_ExchangeSelBoth"
    public static let invertFiles: CommandID = "cm_ExchangeSelFiles"
    public static let invertFolders: CommandID = "cm_ExchangeSelFolders"
    /// The Shift variants of Num +, Ctrl+Num + and Num *: the choice of files or files and
    /// folders that is *not* configured (spec 03 › Selection, Keyboard).
    public static let selectGroupOtherChoice: CommandID = "afm_SelectGroupOtherChoice"
    public static let selectAllOtherChoice: CommandID = "afm_SelectAllOtherChoice"
    public static let invertOtherChoice: CommandID = "afm_InvertSelectionOtherChoice"

    // By the item under the cursor.
    public static let selectCurrentExtension: CommandID = "cm_SelectCurrentExtension"
    public static let unselectCurrentExtension: CommandID = "cm_UnselectCurrentExtension"
    public static let selectCurrentName: CommandID = "cm_SelectCurrentName"
    public static let unselectCurrentName: CommandID = "cm_UnselectCurrentName"
    public static let selectCurrentNameAndExtension: CommandID = "cm_SelectCurrentNameExt"
    public static let unselectCurrentNameAndExtension: CommandID = "cm_UnselectCurrentNameExt"
    public static let selectCurrentPath: CommandID = "cm_SelectCurrentPath"
    public static let unselectCurrentPath: CommandID = "cm_UnselectCurrentPath"
    /// `.index`: how many items from the cursor on (default 1); the cursor moves past them.
    public static let select: CommandID = "cm_Select"
    public static let unselect: CommandID = "cm_UnSelect"

    // Saving and loading.
    public static let saveSelection: CommandID = "cm_SaveSelection"
    /// `.text` or `.location`: the file to write; without, the name is asked for.
    public static let saveSelectionToFile: CommandID = "cm_SaveSelectionToFile"
    public static let saveSelectionToFileANSI: CommandID = "cm_SaveSelectionToFileA"
    public static let saveSelectionToFileUnicode: CommandID = "cm_SaveSelectionToFileW"
    /// `.text` or `.location`: the file to read; without, the name is asked for.
    public static let loadSelectionFromFile: CommandID = "cm_LoadSelectionFromFile"
    public static let loadSelectionFromClipboard: CommandID = "cm_LoadSelectionFromClip"

    // Comparing the two panels. `.index` of the first two: 0 = missing, newer, or another
    // size at the same time; 1 = missing only; 2 = another size, or missing.
    public static let compareDirectories: CommandID = "cm_CompareDirs"
    public static let compareDirectoriesWithSubdirectories: CommandID = "cm_CompareDirsWithSubdirs"
    public static let markNewerHideSame: CommandID = "cm_DirMatch"
}
