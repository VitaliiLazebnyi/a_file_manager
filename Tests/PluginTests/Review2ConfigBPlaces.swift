import Foundation
import TestSupport
import Testing

@testable import PlacesPlugin

/// The stored data of Places (review 2): counts, histories, the hotlist and the tree cache.
@Suite
internal struct Review2ConfigBPlaces {
    /// Visit counts stop at the largest number and never go below zero.
    @Test
    internal func frequentCountsSaturateAndArePassedThroughAnImportOfTheMaximum() throws {
        let json = #"{"counts":{"file:///Users/x/dir":9223372036854775807,"file:///neg":-5}}"#
        var frequent = try JSONDecoder().decode(FrequentFolders.self, from: Data(json.utf8))
        #expect(frequent.counts["file:///neg"] == 0)
        frequent.record(URL(fileURLWithPath: "/Users/x/dir"))
        #expect(frequent.counts["file:///Users/x/dir"] == Int.max)
    }

    /// A stored history is cut to what it keeps, and stores no cached key.
    @Test
    internal func aStoredHistoryHoldsNoMoreThanItKeeps() throws {
        let visits = (0..<1_000).map { #"{"location":"file:///d\#($0)","isVisible":true}"# }.joined(separator: ",")
        let history = try JSONDecoder().decode(DirectoryHistory.self, from: Data(#"{"visits":[\#(visits)]}"#.utf8))
        #expect(history.visits.count == DirectoryHistory.storedLimit && history.current?.path == "/d999")
        var again = history
        #expect(again.record(URL(fileURLWithPath: "/d999"), stayedInPrevious: false) == false)
        #expect(again.record(URL(fileURLWithPath: "/d900"), stayedInPrevious: false) && again.current?.path == "/d900")
        // Round trip keeps only what was stored, not the cached key.
        let data = try JSONEncoder().encode(again)
        #expect(String(bytes: data, encoding: .utf8)?.contains("\"key\"") == false)
    }

    /// A password in a location is stored neither in the history nor in the visit counts.
    @Test
    internal func aPasswordInALocationIsNotStoredInTheHistory() throws {
        var history = DirectoryHistory()
        history.record(try #require(URL(string: "ftp://u:secret@host/dir")), stayedInPrevious: false)
        #expect(history.visits.first?.location.contains("secret") == false)
        var frequent = FrequentFolders()
        frequent.record(try #require(URL(string: "ftp://u:secret@host/dir")))
        #expect(frequent.counts.keys.allSatisfy { !$0.contains("secret") })
    }

    /// Hotlist entries for folders with awkward names lead back to them.
    @Test
    internal func hotlistEntriesForAwkwardFoldersLeadBackToThem() {
        for path in ["/x/trailing ", " /x/leading", "/x/:", "/x/a:", "/x/\"q\"", "/x/plain"] {
            let command = HotlistAction.changeDirectoryCommand(to: path)
            #expect(HotlistAction(command) == .changeDirectory(path: path, focusingOnIt: false), "\(path)")
        }
        #expect(HotlistAction("cd /x/y/:") == .changeDirectory(path: "/x/y", focusingOnIt: true))
    }

    /// Tree cache files are readable by the user alone, and the newest store wins.
    @Test
    internal func treeCacheFilesAreMode0600InAFolderOf0700AndNeverGoBackToAnOlderState() throws {
        let box = try Sandbox()
        let cache = TreeCache(directory: box.url("cache"))
        let root = URL(fileURLWithPath: "/Volumes/R2")
        cache.store(["a", "b"], for: root)
        let file = try #require(cache.fileURL(for: root))
        func mode(_ url: URL) -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int) ?? -1
        }
        #expect(mode(file) == 0o600 && mode(box.url("cache")) == 0o700)
        // The newest store wins, and what is left is no temporary file.
        for round in 0..<20 { cache.store((0...round).map { "f\($0)" }, for: root) }
        cache.flush()
        #expect(TreeCache(directory: box.url("cache")).entry(for: root)?.paths.count == 20)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: box.url("cache").path)
            .filter { $0.contains(".tmp") }
        #expect(leftovers.isEmpty)
    }

    /// Paths with line breaks are left out of the tree cache, which then counts as partial.
    @Test
    internal func treeCachePathsWithLineBreaksAreLeftOutAndTheTreeCountsAsPartial() throws {
        let root = URL(fileURLWithPath: "/Volumes/R2")
        let text = TreeCache.format(TreeCache.Entry(paths: ["ok", "bad\n[injected]", "fine"]), root: root)
        let entry = try #require(TreeCache.parseEntry(text, root: root))
        #expect(entry.paths == ["ok", "fine"] && !entry.isComplete)
    }

    /// A tree cache file over the size limit is not read.
    @Test
    internal func treeCacheFileOverTheLimitIsNotRead() throws {
        let box = try Sandbox()
        let cache = TreeCache(directory: box.url("cache"))
        let root = URL(fileURLWithPath: "/Volumes/R2")
        let file = try #require(cache.fileURL(for: root))
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let line = "[" + String(repeating: "x", count: 1_022) + "]\n"
        var text = "root=" + root.absoluteString + "\n"
        text += String(repeating: line, count: TreeCache.fileLimit / line.utf8.count + 10)
        try text.write(to: file, atomically: true, encoding: .utf8)
        #expect(cache.entry(for: root) == nil)
    }
}
