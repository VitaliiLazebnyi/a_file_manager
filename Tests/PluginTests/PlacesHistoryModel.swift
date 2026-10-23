import Foundation
import TestSupport
import Testing

@testable import PlacesPlugin

/// The history of a panel and the frequently used folders, as values.
@Suite
internal struct PlacesHistoryModel {
    /// The location of the file path `path`.
    internal func url(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: false) }

    /// The history records every place once, the last visited last, and shows them newest first.
    @Test
    internal func recordsEveryPlaceOnceTheLastVisitedLast() {
        var history = DirectoryHistory()
        let (first, again) = (
            history.record(url("/a"), stayedInPrevious: false), history.record(url("/a/"), stayedInPrevious: true)
        )
        #expect(first && !again)
        history.record(url("/b"), stayedInPrevious: true)
        history.record(url("/c"), stayedInPrevious: false)
        history.record(url("/a"), stayedInPrevious: true)
        #expect(history.visits.map(\.location) == ["file:///b", "file:///c", "file:///a"])
        #expect(history.current == url("/a"))
        #expect(history.shown(thinning: false).map(\.path) == ["/a", "/c", "/b"])
        #expect(history.shown(thinning: false, limit: 2).map(\.path) == ["/a", "/c"])
    }

    /// Thinning hides folders that were only passed through, unless one counted before.
    @Test
    internal func thinningHidesFoldersThatWereOnlyPassedThrough() {
        var history = DirectoryHistory()
        history.record(url("/a"), stayedInPrevious: false)
        history.record(url("/a/b"), stayedInPrevious: true)  // stayed in /a
        history.record(url("/a/b/c"), stayedInPrevious: false)  // passed through /a/b
        history.record(url("/a/b/c/d"), stayedInPrevious: false)  // passed through /a/b/c
        #expect(history.shown(thinning: true).map(\.path) == ["/a/b/c/d", "/a"])
        #expect(history.shown(thinning: false).count == 4)
        // A folder that once counted keeps counting when it is passed through later.
        history.record(url("/a"), stayedInPrevious: false)
        history.record(url("/z"), stayedInPrevious: false)
        #expect(history.shown(thinning: true).map(\.path) == ["/z", "/a"])
        history.remove(url("/a"))
        #expect(history.shown(thinning: false).map(\.path) == ["/z", "/a/b/c/d", "/a/b/c", "/a/b"])
    }

    /// The history keeps no more than its stored limit, dropping the oldest visits.
    @Test
    internal func keepsNoMoreThanTheStoredLimit() {
        var history = DirectoryHistory()
        for index in 0..<(DirectoryHistory.storedLimit + 20) {
            history.record(url("/d\(index)"), stayedInPrevious: true)
        }
        #expect(history.visits.count == DirectoryHistory.storedLimit)
        #expect(history.visits.first?.location == "file:///d20")
    }

    /// The frequently used folders are ranked by their visits and keep no more than their limit.
    @Test
    internal func frequentFoldersAreRankedByVisits() {
        var frequent = FrequentFolders()
        for path in ["/a", "/b", "/a", "/c", "/a", "/b"] { frequent.record(url(path)) }
        #expect(frequent.top().map(\.directory.path) == ["/a", "/b", "/c"])
        #expect(frequent.top().map(\.visits) == [3, 2, 1])
        #expect(frequent.top(1).map(\.directory.path) == ["/a"])
        frequent.remove(url("/a"))
        #expect(frequent.top().map(\.directory.path) == ["/b", "/c"])
        for index in 0..<(FrequentFolders.storedLimit + 10) { frequent.record(url("/n\(index)")) }
        #expect(frequent.counts.count == FrequentFolders.storedLimit && frequent.top(1).first?.directory.path == "/b")
    }

    /// The menu lists the history, the current folder marked, then the frequently used folders.
    @Test
    internal func menuListsHistoryThenFrequentFolders() {
        let menu = HistoryMenu(
            history: [url("/b"), url("/a")],
            frequent: [(url("/a"), 7)],
            current: url("/a")
        ) { location in
            location.path
        }
        #expect(menu.titles == ["    /b", "➤ /a", "──────  Frequently used  ──────", "    /a   (7)"])
        #expect(menu.rows == [.visit(url("/b")), .visit(url("/a")), .separator, .frequent(url("/a"))])
        #expect(menu.selected == 1 && menu.rows[2].directory == nil)
        #expect(HistoryMenu(history: [], frequent: [], current: url("/a")) { $0.path }.rows.isEmpty)
    }

    /// The tracker measures how long each folder was shown and saves what it learnt, or only on request when
    /// saving is off.
    @MainActor
    @Test
    internal func trackerMeasuresStaysAndSavesToTheSettings() {
        let settings = MemorySettings()
        var time = Date(timeIntervalSince1970: 1_000)
        let tracker = DirectoryHistoryTracker(settings: settings) { time }
        tracker.visited(url("/a"), on: .left)
        time += 10
        tracker.visited(url("/b"), on: .left)
        time += 1
        tracker.visited(url("/c"), on: .left)
        tracker.visited(url("/c"), on: .left)
        tracker.visited(url("/r"), on: .right)
        #expect(tracker.history(of: .left).shown(thinning: true).map(\.path) == ["/c", "/a"])
        #expect(tracker.history(of: .right).shown(thinning: true).map(\.path) == ["/r"])
        #expect(tracker.frequent.top().map(\.visits) == [1, 1, 1, 1])

        // Changes are written shortly after a burst of navigation, or on request.
        tracker.flush()
        let restarted = DirectoryHistoryTracker(settings: settings) { time }
        #expect(restarted.history(of: .left) == tracker.history(of: .left) && restarted.frequent == tracker.frequent)
        restarted.remove(url("/a"), from: .left)
        restarted.removeFrequent(url("/r"))
        #expect(restarted.history(of: .left).shown(thinning: false).map(\.path) == ["/c", "/b"])
        #expect(restarted.frequent.top().count == 3)
        restarted.clear()
        #expect(DirectoryHistoryTracker(settings: settings).history(of: .left).visits.isEmpty)

        // With saving off, nothing reaches the settings until "Save now".
        let quiet = DirectoryHistoryTracker(settings: settings) { time }
        quiet.savesChanges = { false }
        quiet.visited(url("/q"), on: .right)
        quiet.flush()
        #expect(DirectoryHistoryTracker(settings: settings).history(of: .right).visits.isEmpty)
        quiet.save()
        #expect(DirectoryHistoryTracker(settings: settings).history(of: .right).current == url("/q"))
    }
}
