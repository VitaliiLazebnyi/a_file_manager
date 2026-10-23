import AFMKernel

/// The commands of this plugin that the kernel does not name itself.
extension CommandID {
    /// Ctrl+←: shows the folder under the cursor in the left panel (spec 03 › Moving between directories).
    internal static let transferLeft: CommandID = "cm_TransferLeft"
    /// Ctrl+→: shows the folder under the cursor in the right panel (spec 03 › Moving between directories).
    internal static let transferRight: CommandID = "cm_TransferRight"
    /// Shows the next entry of the volume list in the source panel.
    internal static let nextVolume: CommandID = "cm_GoToNextDrive"
    /// Shows the previous entry of the volume list in the source panel.
    internal static let previousVolume: CommandID = "cm_GoToPreviousDrive"
    /// The reverse of Target = Source: the source panel shows the target panel's directory.
    internal static let sourceEqualsTarget: CommandID = "afm_MatchTrg"
    /// Shows the path the clipboard's text starts with in the source panel.
    internal static let changeDirectoryFromClipboard: CommandID = "afm_CdFromClipboard"
    /// Shows the user's Desktop folder in the source panel.
    internal static let goToDesktop: CommandID = "afm_GoDesktop"
    /// Shows the user's Documents folder in the source panel.
    internal static let goToDocuments: CommandID = "afm_GoDocuments"
    /// Shows the user's Downloads folder in the source panel.
    internal static let goToDownloads: CommandID = "afm_GoDownloads"
    /// Shows `/Applications` in the source panel.
    internal static let goToApplications: CommandID = "afm_GoApplications"
    /// Shows `/Volumes`, the mounted disks, in the source panel.
    internal static let goToVolumes: CommandID = "afm_GoVolumes"
    /// Shows the user's Trash folder in the source panel.
    internal static let goToTrash: CommandID = "afm_GoTrash"
}
