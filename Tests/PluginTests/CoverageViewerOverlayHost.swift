import AFMShell
import AppKit

/// Stands in for the part of a panel the quick view covers.
@MainActor
internal final class CoverageViewerOverlayHost: PanelOverlayHost {
    /// What covers the file list now.
    internal var overlay: NSView?

    deinit {
        // Nothing to release.
    }
}
