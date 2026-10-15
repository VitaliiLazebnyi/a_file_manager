@testable import MacIntegrationPlugin

/// A Quick Look panel that is only a state: shown or not, and what it was asked.
@MainActor
internal final class CoverageMacPreview: PreviewPanel {
    /// Whether the panel counts as on screen.
    private var visible = false
    /// How often the plugin asked whether the panel is on screen.
    internal private(set) var visibilityQuestions = 0

    /// Whether the panel counts as on screen; each question is counted.
    internal var isVisible: Bool {
        visibilityQuestions += 1
        return visible
    }
    /// What the panel was asked, in order: `show`, `reload`, `close`.
    internal private(set) var calls: [String] = []
    /// The feeder it was last shown for.
    internal private(set) weak var feeder: QuickLookController?

    /// A panel that is not on screen.
    internal init() {
        // Not shown yet.
    }

    /// Shows the panel for `controller`.
    internal func show(for controller: QuickLookController) {
        (visible, feeder) = (true, controller)
        calls.append("show")
    }

    /// Notes a reload.
    internal func reload() {
        calls.append("reload")
    }

    /// Takes the panel off the screen.
    internal func close() {
        visible = false
        calls.append("close")
    }

    deinit {
        // Nothing to release.
    }
}
