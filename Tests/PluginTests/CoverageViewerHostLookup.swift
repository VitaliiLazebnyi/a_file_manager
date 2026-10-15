import AFMKernel
import AFMShell

/// Finds the overlay host of the right panel; the left one has none.
@MainActor
internal final class CoverageViewerHostLookup {
    /// The right panel, once the bench made it.
    internal weak var right: (any PanelHandle)?
    /// Its host.
    internal var rightHost: CoverageViewerOverlayHost?

    /// The host of `panel`, if it has one.
    internal func host(for panel: any PanelHandle) -> (any PanelOverlayHost)? {
        panel === right ? rightHost : nil
    }

    deinit {
        // Nothing to release.
    }
}
