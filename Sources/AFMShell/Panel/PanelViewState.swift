import AFMKernel

/// What a panel remembers of its looks between sessions: the layout of the list, the plugin columns
/// it shows and the widths of all its columns (spec 03 › View types, 03 › Column widths).
///
/// Kept per panel under `left.view` and `right.view`.
internal struct PanelViewState: Codable, Equatable {
    /// The settings keys of the left and the right panel, in that order.
    internal static let keys = ["left.view", "right.view"]

    /// The raw value of a `PanelViewMode`.
    internal var mode = PanelViewMode.full.rawValue
    /// Ids of the plugin columns, in display order.
    internal var extraColumns: [String] = []
    /// Width in points by column identifier (`FileListColumn` raw values, plugin columns with
    /// their prefix).
    internal var columnWidths: [String: Double] = [:]

    /// The layout `mode` stands for; the Full view for a value no layout has.
    internal var viewMode: PanelViewMode { PanelViewMode(rawValue: mode) ?? .full }
}
