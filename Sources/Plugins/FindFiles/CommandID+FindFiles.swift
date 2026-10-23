import AFMKernel

/// The commands of Find Files beyond the shared `cm_SearchFor`.
extension CommandID {
    /// A further Find Files window that searches on its own, so several searches can run side
    /// by side (the spec's "separate process", 09 › Window and modes).
    internal static let searchStandalone: CommandID = "cm_SearchStandalone"
    /// Find Files starting in the folder under the cursor.
    internal static let searchInCursorDirectory: CommandID = "cm_SearchForInCurDir"
}
