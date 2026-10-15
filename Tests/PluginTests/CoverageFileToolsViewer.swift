import AFMContracts
import Foundation

/// A viewer that notes the texts it is asked to show.
@MainActor
internal final class CoverageFileToolsViewer: ViewerService {
    /// The titles of the texts shown, in order.
    internal private(set) var titles: [String] = []

    /// A viewer that has shown nothing.
    internal init() {
        // Nothing is shown yet.
    }

    /// Notes nothing: no file is viewed by these tests.
    internal func view(_: URL) {
        // Not asked for here.
    }

    /// Notes the title.
    internal func view(text _: String, title: String) {
        titles.append(title)
    }

    deinit {
        // Nothing to release.
    }
}
