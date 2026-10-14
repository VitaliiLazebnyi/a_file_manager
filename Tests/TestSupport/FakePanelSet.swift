public import AFMKernel

/// The two fake panels of a test, with the left one as the source to begin with.
///
/// Main thread only.
public final class FakePanelSet: PanelSet {
    /// The left panel, as the fake it is.
    public let leftPanel: FakePanel
    /// The right panel, as the fake it is.
    public let rightPanel: FakePanel
    /// The active panel; a test may set it, or call `focus()` on a panel.
    public var source: any PanelHandle

    /// The left panel.
    public var left: any PanelHandle { leftPanel }
    /// The right panel.
    public var right: any PanelHandle { rightPanel }
    /// The panel that is not the source.
    public var target: any PanelHandle { source === leftPanel ? rightPanel : leftPanel }

    /// Pairs the two panels; each learns its pair, weakly.
    public init(left: FakePanel, right: FakePanel) {
        leftPanel = left
        rightPanel = right
        source = left
        left.owner = self
        right.owner = self
    }

    deinit {
        // Nothing to release.
    }
}
