import Foundation

/// Where a link that may be opened goes.
@MainActor
internal protocol LinkOpening {
    /// Opens `url`.
    func open(_ url: URL)
}
