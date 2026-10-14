@testable import AFMKernel

/// Two recording panels, which keep nothing of the directories they show.
@MainActor
internal final class PanelsRecordingPanels: PanelSet {
    /// The left panel.
    internal let left: any PanelHandle
    /// The right panel.
    internal let right: any PanelHandle
    /// The left panel.
    internal var source: any PanelHandle { left }
    /// The right panel.
    internal var target: any PanelHandle { right }

    /// The two panels.
    internal init(_ left: PanelsRecordingPanel, _ right: PanelsRecordingPanel) {
        (self.left, self.right) = (left, right)
    }

    deinit {
        // Nothing to release.
    }
}
