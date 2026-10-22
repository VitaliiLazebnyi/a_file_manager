@testable import AFMShell

/// What the tests wait for before they look at the panels.
extension PanelCoordinator {
    /// True while either panel is reading a folder.
    internal var isLoading: Bool { leftPanel.isLoading || rightPanel.isLoading }
}
