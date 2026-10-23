import AFMContracts
public import AFMKernel
public import AppKit

/// The Mark menu (spec 03 › Selection, 09 › Compare directories and Mark newer).
///
/// The commands change the model's selection; the panel redraws by itself.
public final class SelectionPlugin: Plugin {
    /// The name of the plugin.
    public let name = "Selection"
    private let pasteboard: NSPasteboard
    private let background: Bool
    /// The behaviour behind the commands, kept for as long as the plugin is.
    private var behaviour: Selections?
    /// Where the work that can take long is done: on a thread of the kernel's own.
    ///
    /// Set before the plugin starts; tests hold the work back, to change a list while it is under
    /// way.
    internal var runsWork: @Sendable (@escaping @Sendable () -> Void) -> Void = { BlockingCalls.run($0) }

    /// Tests pass a pasteboard of their own, so they leave the user's clipboard alone.
    ///
    /// With `background` false everything is worked out on the calling thread and has taken effect
    /// when a command returns; otherwise the commands that can take long (a regular expression, a
    /// long list, comparing two folders, the clipboard) work off the main thread and the selection
    /// changes when they are done.
    public init(pasteboard: NSPasteboard = .general, background: Bool = true) {
        self.pasteboard = pasteboard
        self.background = background
    }

    /// Registers the commands of the Mark menu and adds them to the menus and the toolbar.
    public func start(in owner: Kernel) {
        let selections = Selections(owner, pasteboard: pasteboard, background: background, runsWork: runsWork)
        behaviour = selections
        Self.register(selections, in: owner)
    }

    deinit {
        // Nothing to release.
    }
}
