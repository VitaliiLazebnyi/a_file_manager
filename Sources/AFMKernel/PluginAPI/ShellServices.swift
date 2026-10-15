/// What the window shell provides to plugins once it exists.
///
/// Main thread.
@preconcurrency
@MainActor
public protocol ShellServices: AnyObject {
    /// The two file panels.
    var panels: any PanelSet { get }
    /// Runs long work with a progress window.
    var jobs: any JobService { get }
}
