/// What happens in the panels, for plugins that follow them (a quick-view pane follows the
/// cursor, a tree follows the directory).
public enum PanelEvent: Sendable {
    /// This panel became the source.
    case becameSource
    /// The cursor is on another item, or the panel's list changed under it.
    case cursorMoved
    /// The panel shows another directory or another tab.
    case locationChanged
    /// The marked items changed.
    case selectionChanged
}
