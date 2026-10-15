import Foundation

@testable import AFMKernel

/// A panel that records what it was asked to do.
@MainActor
internal final class PanelsRecordingPanel: PanelHandle {
    /// The panel's tabs.
    internal let tabs: PanelTabs
    /// The layout.
    internal var viewMode = PanelViewMode.full
    /// Extra columns.
    internal var extraColumns: [String] = []
    /// What `show` was asked for.
    internal var shown: [(URL, String?)] = []
    /// What `reload` was asked for.
    internal var reloads: [(String?, Bool)] = []

    /// A panel with one tab at `directory`.
    internal init(_ directory: URL) {
        tabs = PanelTabs(PanelModel(directory: directory))
    }

    /// Records the location and says it worked.
    internal func show(
        _ location: URL,
        focus: String?,
        history _: PanelModel.HistoryEffect,
        completion: (@MainActor (Bool) -> Void)?
    ) {
        shown.append((location, focus))
        completion?(true)
    }

    /// Records the reload.
    internal func reload(focus: String?, quietly: Bool, completion: (@MainActor () -> Void)?) {
        reloads.append((focus, quietly))
        completion?()
    }

    /// Takes no keyboard.
    internal func focus() {
        // A recording panel takes no keyboard.
    }

    deinit {
        // Nothing to release.
    }
}
