public import Foundation

/// A file panel as plugins see it.
///
/// Its state is in the models (`tabs`): a plugin changes a model and the panel on screen follows by
/// itself. What needs the file system goes through the calls below, which read in the background
/// and never block. Main thread only.
@MainActor
@preconcurrency
public protocol PanelHandle: AnyObject {
    /// The panel's folder tabs.
    var tabs: PanelTabs { get }
    /// How the list is laid out (spec 03 › View types).
    var viewMode: PanelViewMode { get set }
    /// The plugin-provided columns shown after the standard ones, by their ids
    /// (`ColumnRegistry`); only the Full view shows them.
    var extraColumns: [String] { get set }

    /// Shows a location in the active tab.
    ///
    /// The location of a file leads to its folder, with the cursor on the file; otherwise the
    /// cursor goes to `focus`. A failure is reported to the user and leaves the panel where it was.
    /// `completion` tells whether it worked.
    func show(
        _ location: URL,
        focus: String?,
        history: PanelModel.HistoryEffect,
        completion: (@MainActor (Bool) -> Void)?
    )
    /// Reads the active tab's directory again.
    ///
    /// With `quietly`, nothing is redrawn unless something changed (for changes made by other
    /// programs).
    func reload(focus: String?, quietly: Bool, completion: (@MainActor () -> Void)?)
    /// Gives the panel the keyboard, which makes it the source.
    func focus()
}

/// The calls every panel answers the same way, made of the ones it implements.
extension PanelHandle {
    /// The tab that is shown.
    public var model: PanelModel { tabs.active }

    /// Shows a location in the active tab, without waiting to hear whether it worked.
    public func show(_ location: URL, focus: String? = nil, history: PanelModel.HistoryEffect = .record) {
        show(location, focus: focus, history: history, completion: nil)
    }

    /// Reads the active tab's directory again, and redraws it.
    public func reload(focus: String? = nil) {
        reload(focus: focus, quietly: false, completion: nil)
    }
}
