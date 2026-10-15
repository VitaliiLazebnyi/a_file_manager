public import AppKit

/// What a panel on screen offers beyond `PanelHandle`, to plugins that put views of their own
/// into the window: `kernel.panels.target as? PanelOverlayHost`.
@MainActor
@preconcurrency
public protocol PanelOverlayHost: AnyObject {
    /// A view shown in place of the panel's file list (the quick-view pane, spec 03 › Quick
    /// View); nil brings the list back. The panel keeps its directory, tabs and state.
    var overlay: NSView? { get set }
}
