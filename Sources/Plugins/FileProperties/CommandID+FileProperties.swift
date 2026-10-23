import AFMKernel

/// Commands only this plugin provides (spec 17 › Command catalogue).
extension CommandID {
    /// Edits the comment of the item under the cursor (Ctrl+Z).
    internal static let editComment: CommandID = "cm_EditComment"
    /// Creates links to the operands (Ctrl+Shift+F5).
    internal static let createShortcut: CommandID = "cm_CreateShortcut"
    /// Calculates the size of every folder of the source panel (Alt+Shift+Enter).
    internal static let countDirectoryContents: CommandID = "cm_CountDirContent"
    /// Goes to the item the link under the cursor leads to.
    internal static let showLinkTarget: CommandID = "afm_ShowLinkTarget"
    /// Opens Finder's Info window of the operands.
    internal static let finderInfo: CommandID = "afm_FinderInfo"
}
