import AFMKernel
import AppKit

/// How a row of a list is drawn, the same in every view: its entry, the colour of its text and
/// whether its file may show its own icon.
internal struct RowLook {
    /// The entry; nil for the `[..]` row.
    internal let item: FileItem?
    /// The colour of the text (`PanelViewController.nameColor`); clear leaves the name out.
    internal let color: NSColor
    /// Whether a file may be asked for its own icon (`FileListColumn.icon(for:own:)`).
    internal let ownIcons: Bool
}
