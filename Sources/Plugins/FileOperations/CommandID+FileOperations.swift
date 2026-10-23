import AFMKernel

/// Command names only this plugin uses. The `cm_` ones are the spec's (17 › Command
/// catalogue); the `afm_` ones exist only here.
extension CommandID {
    /// Copy to the other panel, with the dialog (the spec's "Copy to other").
    internal static let copyOtherPanel: CommandID = "cm_CopyOtherpanel"
    /// F6 as a move, with the dialog.
    internal static let moveOnly: CommandID = "cm_MoveOnly"
    /// `.text`: the new name; without, the name under the cursor is edited in place, whatever is selected.
    internal static let renameSingleFile: CommandID = "cm_RenameSingleFile"
    /// Shift+F7: a new folder in the folder of the other panel.
    internal static let makeDirectoryOther: CommandID = "cm_MkDirOther"
    /// Copy with the dialog that shows every option.
    internal static let copyWithOptions: CommandID = "afm_CopyWithOptions"
    /// Rename or move with the dialog that shows every option.
    internal static let moveWithOptions: CommandID = "afm_MoveWithOptions"
    /// Copy to the other panel under the same names, at once, without a dialog.
    internal static let copyNoAsk: CommandID = "afm_CopyNoAsk"
    /// Move to the other panel under the same names, at once, without a dialog.
    internal static let moveNoAsk: CommandID = "afm_MoveNoAsk"
}
