import AFMKernel

/// The marked items by name, for comparing with the names a test expects. The program asks
/// for the marked entries themselves (`operandsSnapshot()`); names are what tests write.
extension PanelModel {
    /// The names of the marked items; two marked entries of one name count once.
    internal var selection: Set<String> { Set(selectedNames) }

    /// The names of the marked items in the order of the list, one for every marked entry.
    internal var selectedNames: [String] { operandsSnapshot().markedItems().map(\.name) }
}
