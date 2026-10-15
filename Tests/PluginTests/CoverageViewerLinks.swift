import Foundation

@testable import ViewerPlugin

/// Keeps the links the viewer would open, in order, instead of opening them.
@MainActor
internal final class CoverageViewerLinks: LinkOpening {
    /// What was opened.
    internal private(set) var opened: [URL] = []

    /// Keeps `url`.
    internal func open(_ url: URL) {
        opened.append(url)
    }

    deinit {
        // Nothing to release.
    }
}
