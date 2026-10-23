public import AFMKernel

/// The commands only this plugin provides (spec 17 › Clipboard).
///
/// The `Net` variants write URLs, which is what a UNC path is on the Mac.
public enum ClipboardCommands {
    /// Copies the names of the operands, one per line.
    public static let copyNames: CommandID = "cm_CopyNamesToClip"
    /// Copies the URLs of the operands, one per line.
    public static let copyNetNames: CommandID = "cm_CopyNetNamesToClip"
    /// Copies the folder of each operand, one per line.
    public static let copyPathOfFiles: CommandID = "cm_CopyPathOfFilesToClip"
    /// Copies the path of the source panel's folder.
    public static let copySourcePath: CommandID = "cm_CopySrcPathToClip"
    /// Copies the path of the target panel's folder.
    public static let copyTargetPath: CommandID = "cm_CopyTrgPathToClip"
    /// Copies the names with every column of the panel, tab-separated.
    ///
    /// `.index`: a bit mask of the columns to copy (1 = name, 2 = size, 4 = date, …); without, all.
    public static let copyDetails: CommandID = "cm_CopyFileDetailsToClip"
    /// Copies the full paths with every column of the panel.
    public static let copyDetailsWithPath: CommandID = "cm_CopyFpFileDetailsToClip"
    /// Copies the URLs with every column of the panel.
    public static let copyDetailsWithURL: CommandID = "cm_CopyNetFileDetailsToClip"
    /// Copies the names with every column of the panel, under a line of column titles.
    public static let copyDetailsWithHeaders: CommandID = "cm_CopyHdrFileDetailsToClip"
    /// Copies the full paths with every column of the panel, under a line of column titles.
    public static let copyDetailsWithHeadersAndPath: CommandID = "cm_CopyHdrFpFileDetailsToClip"
    /// Copies the URLs with every column of the panel, under a line of column titles.
    public static let copyDetailsWithHeadersAndURL: CommandID = "cm_CopyHdrNetFileDetailsToClip"
    /// Writes the names with every column of the panel to a file.
    ///
    /// `.text`: the file to write, as the user would type it; without, the name is asked for.
    public static let saveDetails: CommandID = "cm_SaveDetailsToFile"
    /// Writes the names with every column of the panel to a file, under a line of column titles.
    public static let saveDetailsWithHeaders: CommandID = "cm_SaveHdrDetailsToFile"
}
