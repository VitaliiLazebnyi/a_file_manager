import Foundation

/// What the plugin asks of the Mac's desktop: other applications, Finder, the panels of the
/// system. Everything the plugin decides is decided before it gets here; an implementation
/// only passes the request on (`SystemDesktop`), or notes it (tests).
///
/// `open` and `reveal` may be called on any thread; the others on the main thread.
internal protocol MacDesktop: AnyObject, Sendable {
    /// The Quick Look panel of the system.
    @MainActor var preview: any PreviewPanel { get }
    /// Opens the files with an application.
    func open(_ urls: [URL], with application: URL)
    /// Opens a file with its own application.
    func open(_ url: URL)
    /// Shows the items selected in a Finder window.
    func reveal(_ urls: [URL])
    /// Lets the user pick an application; nil when they did not.
    @MainActor
    func chooseApplication(title: String) -> URL?
    /// Offers the items to the sharing services of the system.
    @MainActor
    func share(_ urls: [URL])
}
