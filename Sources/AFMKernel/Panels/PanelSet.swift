public import Foundation

/// The two panels of the main window (spec 01 › Two panels: source and target).
@MainActor
@preconcurrency
public protocol PanelSet: AnyObject {
    /// The left panel.
    var left: any PanelHandle { get }
    /// The right panel.
    var right: any PanelHandle { get }
    /// The active panel; almost every command acts on it.
    var source: any PanelHandle { get }
    /// The other panel; the default destination of two-sided operations.
    var target: any PanelHandle { get }
    /// The contents of these directories were changed by an operation, whether or not a panel shows
    /// them.
    ///
    /// Called by `refresh`, for whoever keeps directory contents in memory; operations themselves
    /// only ever call `refresh`.
    func contentsChanged(in directories: [URL])
}

/// What both panels do together.
extension PanelSet {
    /// Both panels, left first.
    public var all: [any PanelHandle] { [left, right] }

    /// Keeps nothing in memory, so there is nothing to forget.
    public func contentsChanged(in _: [URL]) {
        // Nothing is kept.
    }

    /// Re-reads every panel that shows one of the directories, after an operation changed them, and
    /// lets go of what is remembered of those no panel shows.
    ///
    /// `focus` is an item the cursor should go to in the panels that show its folder.
    public func refresh(_ directories: [URL], focus: URL? = nil) {
        contentsChanged(in: directories)
        for panel in all where directories.contains(where: { $0.isSameLocation(as: panel.model.directory) }) {
            let inFocusFolder =
                focus.map { $0.deletingLastPathComponent().isSameLocation(as: panel.model.directory) } ?? false
            panel.reload(focus: inFocusFolder ? focus?.lastPathComponent : nil, quietly: false, completion: nil)
        }
    }
}
