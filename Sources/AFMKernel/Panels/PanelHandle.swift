public import Foundation

/// A file panel as plugins see it. Its state is in the models (`tabs`): a plugin changes a
/// model and the panel on screen follows by itself. What needs the file system goes through
/// the calls below, which read in the background and never block. Main thread only.
@MainActor
public protocol PanelHandle: AnyObject {
    var tabs: PanelTabs { get }
    /// True while a directory is being read for this panel.
    var isLoading: Bool { get }

    /// Shows a location in the active tab. The location of a file leads to its folder, with
    /// the cursor on the file; otherwise the cursor goes to `focus`. A failure is reported to
    /// the user and leaves the panel where it was. `completion` tells whether it worked.
    func show(_ location: URL, focus: String?, history: PanelModel.HistoryEffect, completion: ((Bool) -> Void)?)
    /// Reads the active tab's directory again. With `quietly`, nothing is redrawn unless
    /// something changed (for changes made by other programs).
    func reload(focus: String?, quietly: Bool, completion: (() -> Void)?)
    /// Gives the panel the keyboard, which makes it the source.
    func focus()
    /// How the list is laid out (spec 03 › View types).
    var viewMode: PanelViewMode { get set }
    /// The plugin-provided columns shown after the standard ones, by their ids
    /// (`ColumnRegistry`); only the Full view shows them.
    var extraColumns: [String] { get set }
}

/// The layouts of a file list (spec 03 › View types).
public enum PanelViewMode: Int, Codable, Sendable {
    /// One row per item with all columns.
    case full = 0
    /// Names only, in several columns side by side.
    case brief = 1
    /// A grid of pictures of the files.
    case thumbnails = 2
}

extension PanelHandle {
    /// The tab that is shown.
    public var model: PanelModel { tabs.active }

    public func show(_ location: URL, focus: String? = nil, history: PanelModel.HistoryEffect = .record) {
        show(location, focus: focus, history: history, completion: nil)
    }

    public func reload(focus: String? = nil) {
        reload(focus: focus, quietly: false, completion: nil)
    }
}

/// The two panels of the main window (spec 01 › Two panels: source and target).
@MainActor
public protocol PanelSet: AnyObject {
    var left: any PanelHandle { get }
    var right: any PanelHandle { get }
    /// The active panel; almost every command acts on it.
    var source: any PanelHandle { get }
    /// The other panel; the default destination of two-sided operations.
    var target: any PanelHandle { get }
    /// The contents of these directories were changed by an operation, whether or not a panel
    /// shows them. Called by `refresh`, for whoever keeps directory contents in memory;
    /// operations themselves only ever call `refresh`.
    func contentsChanged(in directories: [URL])
}

extension PanelSet {
    public var all: [any PanelHandle] { [left, right] }

    public func contentsChanged(in _: [URL]) {}

    /// Re-reads every panel that shows one of the directories, after an operation changed
    /// them, and lets go of what is remembered of those no panel shows. `focus` is an item the cursor should go to in the panels that show its folder.
    public func refresh(_ directories: [URL], focus: URL? = nil) {
        contentsChanged(in: directories)
        for panel in all where directories.contains(where: { $0.isSameLocation(as: panel.model.directory) }) {
            let inFocusFolder =
                focus.map { $0.deletingLastPathComponent().isSameLocation(as: panel.model.directory) } ?? false
            panel.reload(focus: inFocusFolder ? focus?.lastPathComponent : nil, quietly: false, completion: nil)
        }
    }
}
