import AppKit

/// The colour of the row whose cells the table asked for last, with what it was worked out
/// from, so a row costs one evaluation of the colour rules and not one per column.
internal struct PanelRowColor {
    /// The entry's name; nil for the `[..]` row.
    internal let name: String?
    /// Whether the entry is hidden.
    internal let isHidden: Bool
    /// Whether the entry is marked.
    internal let isSelected: Bool
    /// The colour.
    internal let color: NSColor
}
