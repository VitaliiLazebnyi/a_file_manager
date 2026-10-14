public import Foundation

/// The ordered folder tabs of one panel.
///
/// Each tab keeps its own directory, sort order, selection and history (spec 03 › Folder tabs).
/// Like the tabs' models it only holds state: a tab that was never shown is read when it becomes
/// the active one. Main thread only.
@MainActor
@preconcurrency
public final class PanelTabs {
    /// What is remembered of a panel between sessions.
    public struct State: Codable, Equatable, Sendable {
        /// The tabs, in the order of the strip.
        public var tabs: [PanelTabState]
        /// The index of the tab that is shown.
        public var active: Int

        /// A panel's state.
        public init(tabs: [PanelTabState], active: Int) {
            self.tabs = tabs
            self.active = active
        }
    }

    /// The tabs' models, in the order of the strip.
    public private(set) var tabs: [PanelModel]
    /// The index of the tab that is shown.
    public private(set) var activeIndex = 0
    /// Called on the main thread when a tab was opened, closed or activated.
    public var onChange: (() -> Void)?

    /// The tab that is shown.
    public var active: PanelModel { tabs[activeIndex] }
    /// How many tabs there are.
    public var count: Int { tabs.count }

    /// What is remembered of the tabs between sessions.
    public var state: State {
        State(tabs: tabs.map(Self.state(of:)), active: activeIndex)
    }

    /// One tab showing what `first` shows.
    public init(_ first: PanelModel) {
        tabs = [first]
    }

    /// The tabs of the last session, or a single tab showing `fallback`.
    ///
    /// Nothing is read yet.
    public convenience init(restoring state: State?, fallback: URL) {
        let models = (state?.tabs ?? []).compactMap(Self.model(of:))
        self.init(models.first ?? PanelModel(directory: fallback))
        if models.count > 1 { tabs = models }
        activeIndex = min(max(state?.active ?? 0, 0), tabs.count - 1)
    }

    /// The model of a remembered tab; nil when its location is no URL.
    private static func model(of tab: PanelTabState) -> PanelModel? {
        guard let location = URL(string: tab.location) else {
            return nil
        }
        let order = ListOrder(key: SortKey(rawValue: tab.sortKey) ?? .name, descending: tab.descending)
        let model = PanelModel(directory: location, sort: order, showHidden: tab.showHidden)
        (model.customTitle, model.isLocked) = (tab.title, tab.locked)
        return model
    }

    /// What is remembered of a tab.
    private static func state(of model: PanelModel) -> PanelTabState {
        PanelTabState(
            location: model.directory,
            order: model.sort,
            showHidden: model.showHidden,
            title: model.customTitle,
            locked: model.isLocked
        )
    }

    /// Several changes of the tabs announced as one: `onChange` is not called while `changes` runs,
    /// and once afterwards if any of them would have called it.
    ///
    /// Calls may be nested; the announcement comes when the outermost ends.
    public func performBatch(_ changes: () -> Void) {
        let outer = onChange
        var isChanged = false
        onChange = { isChanged = true }
        changes()
        onChange = outer
        if isChanged { outer?() }
    }

    /// The folder name, as shown on the tab.
    public func title(at index: Int) -> String {
        let tab = tabs[index]
        let mark = tab.isLocked ? "*" : ""
        if let title = tab.customTitle {
            return mark + title
        }
        let name = tab.directory.lastPathComponent
        return mark + (name.isEmpty || tab.directory.path == "/" ? "/" : name)
    }

    /// Opens a tab at the end: a copy of the active tab, or one that will show `directory`.
    @discardableResult
    public func openTab(showing directory: URL? = nil, activate: Bool = true) -> PanelModel {
        let tab =
            directory.map { PanelModel(directory: $0, sort: active.sort, showHidden: active.showHidden) }
            ?? active.duplicate()
        tabs.append(tab)
        if activate { activeIndex = tabs.count - 1 }
        onChange?()
        return tab
    }

    /// Opens a tab that will show `directory`, right after the active one or at `index`.
    @discardableResult
    public func insertTab(showing directory: URL, at index: Int? = nil, activate: Bool = true) -> PanelModel {
        let tab = PanelModel(directory: directory, sort: active.sort, showHidden: active.showHidden)
        let position = min(max(index ?? activeIndex + 1, 0), tabs.count)
        tabs.insert(tab, at: position)
        if activate { activeIndex = position } else if position <= activeIndex { activeIndex += 1 }
        onChange?()
        return tab
    }

    /// Moves a tab to another position in the strip; the active tab stays the active one.
    public func moveTab(from index: Int, to destination: Int) {
        guard tabs.indices.contains(index), tabs.indices.contains(destination), index != destination else {
            return
        }
        let activeTab = active
        tabs.insert(tabs.remove(at: index), at: destination)
        activeIndex = tabs.firstIndex { $0 === activeTab } ?? 0
        onChange?()
    }

    /// Closes a tab; the last remaining tab and locked tabs cannot be closed.
    @discardableResult
    public func closeTab(at index: Int) -> Bool {
        guard tabs.count > 1, tabs.indices.contains(index), !tabs[index].isLocked else {
            return false
        }
        tabs.remove(at: index)
        if index < activeIndex || activeIndex == tabs.count { activeIndex -= 1 }
        onChange?()
        return true
    }

    /// Shows the tab at `index`.
    public func activate(_ index: Int) {
        guard tabs.indices.contains(index), index != activeIndex else {
            return
        }
        activeIndex = index
        onChange?()
    }

    /// Ctrl+Tab and Ctrl+Shift+Tab: the tab to the right or left, wrapping around.
    public func activateNeighbour(_ delta: Int) {
        activate((activeIndex + delta + tabs.count) % tabs.count)
    }

    deinit {
        // Nothing to release.
    }
}
