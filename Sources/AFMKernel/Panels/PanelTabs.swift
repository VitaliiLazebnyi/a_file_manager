import Foundation

/// The ordered folder tabs of one panel. Each tab keeps its own directory, sort order,
/// selection and history (spec 03 › Folder tabs). Like the tabs' models it only holds state:
/// a tab that was never shown is read when it becomes the active one. Main thread only.
public final class PanelTabs {
    /// What is remembered of a panel between sessions.
    public struct State: Codable, Equatable {
        public struct Tab: Codable, Equatable {
            /// The location as a URL string, so it can be on any file system.
            public var location: String
            public var sortKey: Int
            public var descending: Bool
            public var showHidden: Bool
            public var title: String?
            public var locked: Bool?

            public init(
                location: URL, sortKey: Int = 0, descending: Bool = false, showHidden: Bool = false,
                title: String? = nil,
                locked: Bool? = nil
            ) {
                self.title = title
                self.locked = locked
                self.location = location.absoluteString
                self.sortKey = sortKey
                self.descending = descending
                self.showHidden = showHidden
            }
        }
        public var tabs: [Tab]
        public var active: Int

        public init(tabs: [Tab], active: Int) {
            self.tabs = tabs
            self.active = active
        }
    }

    public private(set) var tabs: [PanelModel]
    public private(set) var activeIndex = 0
    /// Called on the main thread when a tab was opened, closed or activated.
    public var onChange: (() -> Void)?

    public var active: PanelModel { tabs[activeIndex] }
    public var count: Int { tabs.count }

    /// Several changes of the tabs announced as one: `onChange` is not called while `changes`
    /// runs, and once afterwards if any of them would have called it. Calls may be nested;
    /// the announcement comes when the outermost ends.
    public func performBatch(_ changes: () -> Void) {
        let outer = onChange
        var isChanged = false
        onChange = { isChanged = true }
        changes()
        onChange = outer
        if isChanged { outer?() }
    }

    public init(_ first: PanelModel) {
        tabs = [first]
    }

    /// The tabs of the last session, or a single tab showing `fallback`. Nothing is read yet.
    public convenience init(restoring state: State?, fallback: URL) {
        let models = (state?.tabs ?? []).compactMap { tab in
            URL(string: tab.location).map {
                let model = PanelModel(
                    directory: $0,
                    sort: ListOrder(key: SortKey(rawValue: tab.sortKey) ?? .name, descending: tab.descending),
                    showHidden: tab.showHidden)
                (model.customTitle, model.isLocked) = (tab.title, tab.locked ?? false)
                return model
            }
        }
        self.init(models.first ?? PanelModel(directory: fallback))
        if models.count > 1 { tabs = models }
        activeIndex = min(max(state?.active ?? 0, 0), tabs.count - 1)
    }

    public var state: State {
        State(
            tabs: tabs.map {
                .init(
                    location: $0.directory, sortKey: $0.sort.key.rawValue, descending: $0.sort.descending,
                    showHidden: $0.showHidden, title: $0.customTitle, locked: $0.isLocked ? true : nil)
            },
            active: activeIndex)
    }

    /// The folder name, as shown on the tab.
    public func title(at index: Int) -> String {
        let directory = tabs[index].directory
        if let title = tabs[index].customTitle { return (tabs[index].isLocked ? "*" : "") + title }
        if tabs[index].isLocked { return "*" + (directory.path == "/" ? "/" : directory.lastPathComponent) }
        return directory.lastPathComponent.isEmpty || directory.path == "/" ? "/" : directory.lastPathComponent
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
        guard tabs.indices.contains(index), tabs.indices.contains(destination), index != destination else { return }
        let activeTab = active
        tabs.insert(tabs.remove(at: index), at: destination)
        activeIndex = tabs.firstIndex { $0 === activeTab } ?? 0
        onChange?()
    }

    /// Closes every tab but the active one and the locked ones.
    public func closeOtherTabs() {
        let activeTab = active
        tabs.removeAll { $0 !== activeTab && !$0.isLocked }
        activeIndex = tabs.firstIndex { $0 === activeTab } ?? 0
        onChange?()
    }

    /// Closes a tab; the last remaining tab and locked tabs cannot be closed.
    @discardableResult
    public func closeTab(at index: Int) -> Bool {
        guard tabs.count > 1, tabs.indices.contains(index), !tabs[index].isLocked else { return false }
        tabs.remove(at: index)
        if index < activeIndex || activeIndex == tabs.count { activeIndex -= 1 }
        onChange?()
        return true
    }

    public func activate(_ index: Int) {
        guard tabs.indices.contains(index), index != activeIndex else { return }
        activeIndex = index
        onChange?()
    }

    /// Ctrl+Tab and Ctrl+Shift+Tab: the tab to the right or left, wrapping around.
    public func activateNeighbour(_ delta: Int) {
        activate((activeIndex + delta + tabs.count) % tabs.count)
    }
}
