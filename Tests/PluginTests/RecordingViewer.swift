import AFMContracts
import AFMKernel
import Foundation

/// Offers a viewer that only records what it was asked to show.
@MainActor
internal final class RecordingViewer: Plugin, ViewerService {
    /// The plugin's name in the kernel.
    internal let name = "Recording viewer"
    /// The texts it was asked to show, with their titles, oldest first.
    internal var texts: [(text: String, title: String)] = []

    /// Offers itself as the viewer.
    internal func start(in kernel: Kernel) { kernel.services.register((any ViewerService).self, self) }

    /// Shows no file: only texts are recorded.
    internal func view(_: URL) {
        // Not recorded: the tests look at texts only.
    }

    /// Records `text` and `title`.
    internal func view(text: String, title: String) { texts.append((text, title)) }

    deinit {
        // Nothing to release.
    }
}
