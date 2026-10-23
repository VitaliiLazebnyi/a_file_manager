public import AFMKernel

/// The commands only this plugin provides (spec 17 › Command catalogue), under the spec's
/// names where it has one.
public enum SystemToolsCommands {
    /// Asks for a line and runs it like `CommandID.runCommandLine`.
    public static let runPrompt: CommandID = "afm_RunCommand"
    /// TC's "Open command prompt window": a terminal window in the source folder.
    public static let openTerminal: CommandID = "cm_ExecuteDOS"
    /// The System Information dialog: hardware, macOS and the mounted volumes.
    public static let systemInformation: CommandID = "cm_SysInfo"
    /// TC's "Volume Label": renames the volume the source panel shows.
    public static let renameVolume: CommandID = "cm_VolumeId"
    /// Ejects the drive of the source panel's folder, or of the location it is given.
    public static let ejectVolume: CommandID = "afm_EjectVolume"
    /// Prints the list of the selected items, or of the whole folder.
    public static let printList: CommandID = "cm_PrintDir"
    /// Prints the list with what the folders hold, to a depth and with a mask that are asked for.
    public static let printListWithSubfolders: CommandID = "cm_PrintDirSub"
    /// Sends the selected files to the default printer.
    public static let printFile: CommandID = "cm_PrintFile"
    /// TC's "Associate With": on the Mac, opening the file with an application of choice.
    public static let openWith: CommandID = "cm_Associate"
    /// Files › Quit: closes the program.
    public static let quit: CommandID = "cm_Exit"
    /// Minimizes the main window into the Dock.
    public static let minimize: CommandID = "cm_Minimize"
}
