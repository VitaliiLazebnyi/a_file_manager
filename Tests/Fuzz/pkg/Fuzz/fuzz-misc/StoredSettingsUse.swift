import AFMKernel
import Foundation

@testable import PlacesPlugin

/// What the stored settings are put to after an import (and at the next start).
@MainActor
internal enum StoredSettingsUse {
    /// The folder every reader falls back to.
    private static let base = fixedURL("file:///base/")

    /// Each reader of a known key, driven the way its owner drives it.
    internal static func use(_ settings: any SettingsStore) {
        KeyBindings().load(from: settings)
        for key in ["left.tabs", "right.tabs"] {
            let state = settings.value(PanelTabs.State.self, forKey: key)
            let tabs = PanelTabs(restoring: state, fallback: base)
            for index in 0..<tabs.count {
                _ = tabs.title(at: index)
            }
            _ = tabs.active
            _ = tabs.state
            tabs.activateNeighbour(1)
        }
        let places = settings.scoped(to: "places")
        useHistory(DirectoryHistoryTracker(settings: places))
        useHotlist(in: places)
    }

    /// The history menus of both sides, and the user going to folders they name, and elsewhere.
    private static func useHistory(_ tracker: DirectoryHistoryTracker) {
        for side in DirectoryHistoryTracker.Side.allCases {
            let history = tracker.history(of: side)
            let shown = history.shown(thinning: true, limit: 30) + history.shown(thinning: false)
            let top = tracker.frequent.top(20)
            _ = HistoryMenu(
                history: shown,
                frequent: top,
                current: history.current ?? base
            ) { $0.absoluteString }
            for url in shown.prefix(4) + top.prefix(4).map(\.directory) + [base] {
                tracker.visited(url, on: side)
            }
            if let first = shown.first {
                tracker.remove(first, from: side)
                tracker.removeFrequent(first)
            }
        }
        tracker.flush()
    }

    /// The hotlist's menus and rows, and one row hidden, moved and removed.
    private static func useHotlist(in places: any SettingsStore) {
        let loaded = StoredSettings.load(Hotlist.self, key: "hotlist", in: places) { _ in
            // A stored hotlist that cannot be read is no finding here.
        }
        guard var hotlist = loaded else {
            return
        }
        let rows = hotlist.rows
        _ = hotlist.count
        for row in rows.prefix(200) {
            _ = HotlistAction(row.entry.command)
            _ = HotlistAction.targetPath(row.entry.target)
            _ = row.entry.displayTitle
            _ = hotlist.isHidden(row.entry)
            _ = HotlistMenu(hotlist, at: row.path, offersFavorites: true) { $0.command.hasPrefix("cd") }
        }
        _ = HotlistMenu(hotlist) { _ in false }
        if let first = rows.first {
            hotlist.toggleHideMark(at: first.path)
            _ = hotlist.move(at: first.path, by: 1)
            _ = hotlist.remove(at: first.path)
        }
    }
}
