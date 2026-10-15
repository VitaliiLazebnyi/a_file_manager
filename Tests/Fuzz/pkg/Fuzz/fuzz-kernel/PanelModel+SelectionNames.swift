import AFMKernel

/// The marked items by name, as the checks compare them.
extension PanelModel {
    /// The names of the marked items; two marked entries of one name count once.
    internal var selection: Set<String> { Set(selectedNames) }

    /// The names of the marked items in the order of the list, one for every marked entry.
    internal var selectedNames: [String] { operandsSnapshot().markedItems().map(\.name) }
}
