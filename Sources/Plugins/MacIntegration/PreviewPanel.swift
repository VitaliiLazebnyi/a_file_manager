/// The system's Quick Look panel, as `QuickLookController` uses it.
@MainActor
internal protocol PreviewPanel: AnyObject {
    /// Whether the panel is on screen.
    var isVisible: Bool { get }
    /// Puts the panel on screen, fed by `controller`.
    func show(for controller: QuickLookController)
    /// Has the panel ask its feeder again.
    func reload()
    /// Takes the panel off the screen.
    func close()
}
