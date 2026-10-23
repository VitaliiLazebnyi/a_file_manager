import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FindFilesPlugin

/// Saved searches, the histories of the fields, the summary of a search and the query it makes.
@Suite
internal struct SavedSearches {
    /// Settings that search for `searchFor` in the panel's folder.
    internal func settings(_ searchFor: String) -> SearchSettings {
        settings(searchFor, in: "")
    }

    /// Settings that search for `searchFor` in `searchIn`.
    internal func settings(_ searchFor: String, in searchIn: String) -> SearchSettings {
        var settings = SearchSettings()
        (settings.searchFor, settings.searchIn) = (searchFor, searchIn)
        return settings
    }

    /// Searches are saved under names that differ in more than case, read back and deleted.
    @Test
    internal func savingLoadingAndDeleting() {
        let memory = MemorySettings()
        let store = SearchStore(settings: memory)
        #expect(store.searches.isEmpty)
        var pictures = settings("*.jpg *.png")
        pictures.criteria.size = SizeRule(.greater, 1, .megabytes)
        pictures.duplicates = DuplicateOptions(isEnabled: true, sameContents: true)
        store.save(SavedSearch(name: "Pictures", settings: pictures))
        store.save(SavedSearch(name: "backups", settings: settings("*.bak")))
        #expect(store.searches.map(\.name) == ["backups", "Pictures"])
        // Kept in the settings, in the plugin's own corner; a second store reads the same.
        #expect(memory.data(forKey: "findFiles.searches") != nil)
        #expect(SearchStore(settings: memory)["pictures"]?.settings == pictures)
        store.save(SavedSearch(name: "PICTURES", settings: settings("*.gif")))
        #expect(
            store.searches.map(\.name) == ["backups", "PICTURES"] && store["Pictures"]?.settings.searchFor == "*.gif"
        )
        store.delete(named: "Backups")
        #expect(store.searches.map(\.name) == ["PICTURES"])
    }

    /// A saved field that starts with `>` keeps what the window holds.
    @Test
    internal func aLeadingAngleKeepsTheFieldOfTheWindow() {
        let current = settings("*.swift", in: "/Users/x/src")
        var saved = settings(">", in: ">")
        saved.depth = 2
        let loaded = saved.loaded(over: current)
        #expect(loaded.searchFor == "*.swift" && loaded.searchIn == "/Users/x/src" && loaded.depth == 2)
        #expect(settings("*.md", in: "/tmp").loaded(over: current).searchFor == "*.md")
    }

    /// The summary names what differs from a plain search.
    @Test
    internal func summaryNamesWhatIsNotDefault() {
        #expect(SearchSettings().summary.isEmpty)
        var all = settings("*.txt")
        (all.namesAreRegex, all.findText, all.text, all.searchArchives, all.depth, all.useSpotlight) = (
            true, true, "x", true, 3, true
        )
        all.criteria.olderThan = Age(1, .days)
        all.criteria.size = SizeRule(.less, 5)
        all.criteria.hidden = .set
        all.duplicates = DuplicateOptions(isEnabled: true)
        all.fieldRules = FieldRules(isEnabled: true, rules: [FieldRule("tc.name", .contains, "a")])
        #expect(all.summary == "*.txt, regex, text \"x\", date, zip, size, attr, 2x, D<=3, plugins, Spotlight")
    }

    /// The histories keep the newest entry first, each once, as many as asked.
    @Test
    internal func fieldHistoriesKeepTheNewestFirst() {
        let store = SearchStore(settings: MemorySettings())
        for text in ["a", "b", "c", "a", ""] {
            store.remember(text, in: .searchFor, limit: 2)
        }
        #expect(store.history(.searchFor) == ["a", "c"] && store.history(.text).isEmpty)
        store.forget("a", in: .searchFor)
        #expect(store.history(.searchFor) == ["c"])
    }

    /// The settings become a query: start directories, text, depth and the chosen items.
    @Test
    internal func settingsBecomeAQuery() {
        let (fileSystems, memory) = makeFileSystems()
        var form = settings("*.txt", in: " mem:/work ; /tmp/x;sub ;")
        (form.findText, form.text, form.caseSensitive, form.depth) = (false, "ignored", true, 1)
        form.onlySelected = true
        let base = memory.url("/base")
        var query = form.query(relativeTo: base, fileSystems: fileSystems, includeHidden: true)
        #expect(query.directories.map(\.absoluteString) == ["mem:///work", "mem:///tmp/x", "mem:///base/sub"])
        #expect(
            query.names == "*.txt" && query.text.isEmpty && query.caseSensitive && query.includeHidden
                && query.maxDepth == 1
        )
        // Nothing marked in the panel: the option has nothing to work on.
        #expect(query.scope == .startDirectories)
        form.findText = true
        form.searchIn = ""
        query = form.query(
            relativeTo: base,
            fileSystems: fileSystems,
            includeHidden: false,
            selected: [memory.url("/base/a")]
        )
        #expect(query.directories == [base] && query.text == "ignored" && query.scope == .only([memory.url("/base/a")]))
    }
}
