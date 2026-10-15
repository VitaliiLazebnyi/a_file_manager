import AFMKernel

/// Command names only the window shell uses (spec 17 › Command catalogue).
extension CommandID {
    /// Adds the name of the item under the cursor to the command line.
    internal static let addNameToCommandLine: Self = "cm_AddFileNameToCmdline"
    /// Adds the path and name of the item under the cursor to the command line.
    internal static let addPathAndNameToCommandLine: Self = "cm_AddPathAndFileNameToCmdline"
    /// Adds the path of the source panel to the command line.
    internal static let addPathToCommandLine: Self = "cm_AddPathToCmdline"
    /// Opens the list of the lines run before.
    internal static let commandLineHistory: Self = "cm_ShowCmdLineHistory"
    /// Empties the command line.
    internal static let clearCommandLine: Self = "cm_ClearCmdLine"
    /// Brings back the line run before the one shown.
    internal static let previousCommandLine: Self = "cm_PrevCommand"
    /// Brings back the line run after the one shown.
    internal static let nextCommandLine: Self = "cm_NextCommand"
    /// Provided by whichever plugin edits the button bar; the bar's context menu offers it.
    internal static let changeButtonBar: Self = "cm_ConfigChangeButtonBar"
    /// Not a Total Commander command: puts back the button bar the plugins proposed.
    internal static let resetButtonBar: Self = "cm_ResetButtonBar"
    /// Ejects the drive of the location it is given (the drive of the source panel without one).
    ///
    /// Provided by the system tools. The eject buttons of the drive bar and path bar run it.
    internal static let ejectVolume: Self = "afm_EjectVolume"
}
