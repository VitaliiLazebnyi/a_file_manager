import AFMKernel
public import Foundation

/// Viewing a file in the built-in viewer. Offered by the viewer plugin; used by plugins that
/// produce something to look at (a comparison, a log).
@MainActor
public protocol ViewerService {
    /// Opens a viewer window for the file at `url`, on any file system.
    func view(_ url: URL)
    /// Opens a viewer window for a text that is not a file.
    func view(text: String, title: String)
}
