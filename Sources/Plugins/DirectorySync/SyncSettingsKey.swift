/// The settings keys of Synchronize directories, all below `directorySync.`.
internal enum SyncSettingsKey {
    /// The scope that holds every key below.
    internal static let scope = "directorySync"
    /// The compare options of the window (`SyncOptions`), as last used.
    internal static let options = "options"
    /// The Show buttons (`SyncShow`), as last used.
    internal static let show = "show"
    /// The saved sets (`SyncSet`).
    internal static let sets = "sets"
    /// Whether the comparison runs again after synchronizing (a flag).
    internal static let recompare = "recompareAfterSync"
    /// Whether the Synchronize dialog asks before overwrites by default (a flag).
    internal static let confirmOverwrites = "confirmOverwrites"
    /// Whether deleted files go to the Trash by default (a flag).
    internal static let useTrash = "useTrash"
    /// Whether a source file may take the date of a target that cannot keep its own (a flag).
    internal static let changeSourceDates = "changeSourceDates"
    /// Whether folders that could not be read are reported after a comparison (a flag).
    internal static let warnReadErrors = "warnReadErrors"
}
