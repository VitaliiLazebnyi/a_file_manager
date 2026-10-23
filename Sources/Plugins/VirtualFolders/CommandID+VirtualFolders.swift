import AFMKernel

/// Command names only this plugin uses (spec 17 › Command catalogue).
extension CommandID {
    /// Branch view of the selected folders only (spec 03 › Selected branch).
    internal static let branchViewSelected: CommandID = "cm_DirBranchSel"
    /// Branch view in the left panel, whichever panel is the source.
    internal static let leftBranchView: CommandID = "cm_LeftDirBranch"
    /// Branch view in the right panel, whichever panel is the source.
    internal static let rightBranchView: CommandID = "cm_RightDirBranch"
    /// Branch view of the selected folders in the left panel.
    internal static let leftBranchViewSelected: CommandID = "cm_LeftDirBranchSel"
    /// Branch view of the selected folders in the right panel.
    internal static let rightBranchViewSelected: CommandID = "cm_RightDirBranchSel"
    /// `.location` or `.text`: a text file with one path per line, shown like a search result
    /// (spec 09 › Feed to listbox, `LOADLIST`); without, the user is asked for the file.
    internal static let loadFileList: CommandID = "LOADLIST"
}
