public import AFMKernel

/// The commands of this plugin that the kernel does not name, under the names of the specification.
extension CommandID {
    /// The directory tree of the source panel's volume in a window (spec 12 › Directory Tree dialog).
    public static let directoryTree: CommandID = "cm_CDtree"
    /// The history list with the folders that were only passed through (spec 03 › Directory history list).
    public static let directoryHistoryUnthinned: CommandID = "cm_DirectoryHistoryNoThinning"
    /// "Save now" of the history page (spec 13 › Operation › History).
    public static let saveDirectoryHistory: CommandID = "cm_ConfigSaveDirHistory"
    /// "Delete now" of the history page.
    public static let clearDirectoryHistory: CommandID = "afm_ClearDirectoryHistory"
    /// Adds the source panel's directory to the hotlist, or removes it when it is listed.
    public static let toggleHotlistEntry: CommandID = "afm_HotlistToggleCurrentDir"
    /// The hotlist editor on its own (spec 12 › Directory hotlist editor).
    public static let configureHotlist: CommandID = "afm_ConfigureHotlist"
}
