import AFMKernel
import FindFilesPlugin
import Foundation
import TestSupport
import Testing

/// The saved searches and the field histories of Find Files, as earlier versions wrote them,
/// load as they were meant and are written again in the same shape.
@MainActor
@Suite
internal struct FindFilesSettingsMigration {
    /// What earlier versions wrote, one fixture per format.
    internal enum Fixture {
        /// The saved searches as commit 16d647d (2026-10-14) wrote them.
        ///
        /// `findFiles.searches`: every field of the four tabs; `depth` and the date and size
        /// limits are left out when they are not set, dates are seconds since 2001-01-01 and
        /// choices are numbers. "Big videos" finds films of more than 500 MB changed since
        /// 2026-01-01 and not older than six months, two folders deep, through Spotlight;
        /// "Invoices" finds text files holding the word invoice, with a plugin rule and the
        /// duplicate finder.
        internal static let searches = #"""
            [{"name":"Big videos","settings":{"searchFor":"*.mov *.mp4",\#
            "searchIn":"\/Users\/me\/Movies;\/Volumes\/Media","namesAreRegex":false,"onlySelected":false,\#
            "searchArchives":false,"useSpotlight":true,"depth":2,\#
            "findText":false,"text":"","caseSensitive":false,"textOptions":{"wholeWords":false,"regex":false,\#
            "hex":false,"notContaining":false,"encodings":["utf8"]},"criteria":{"dateFrom":788918400,\#
            "notOlderThan":{"count":6,"unit":4},"size":{"comparison":1,"value":500,"unit":2},"hidden":0,\#
            "directory":2,"symbolicLink":0,"readOnly":0,"executable":0,"package":0},"fieldRules":{"isEnabled":false,\#
            "matchAll":true,"rules":[]},"duplicates":{"isEnabled":false,"sameName":true,"sameSize":true,\#
            "sameContents":false}}},\#
            {"name":"Invoices","settings":{"searchFor":"*.txt *.md","searchIn":"","namesAreRegex":false,\#
            "onlySelected":false,"searchArchives":true,"useSpotlight":false,"findText":true,"text":"invoice",\#
            "caseSensitive":true,"textOptions":{"wholeWords":true,"regex":false,"hex":false,"notContaining":false,\#
            "encodings":["utf8","western"]},"criteria":{"hidden":0,"directory":0,"symbolicLink":0,"readOnly":0,\#
            "executable":0,"package":0},"fieldRules":{"isEnabled":true,"matchAll":false,"rules":[{"field":"name",\#
            "comparison":0,"value":"draft"}]},"duplicates":{"isEnabled":true,"sameName":true,"sameSize":false,\#
            "sameContents":true}}}]
            """#

        /// A field's history as commit 16d647d (2026-10-14) wrote it.
        ///
        /// `findFiles.history.searchFor`: what was typed into "Search for", newest first.
        internal static let searchForHistory = #"["*.mov *.mp4","*.txt"]"#
    }

    /// A store on fresh settings holding the fixtures under their keys.
    private static func store(_ fixtures: [String: String]) -> (store: SearchStore, settings: MemorySettings) {
        let settings = MemorySettings()
        for (key, fixture) in fixtures {
            SettingsJSON.store(fixture, forKey: "findFiles." + key, in: settings)
        }
        return (SearchStore(settings: settings), settings)
    }

    /// Both searches load with the settings of every tab.
    @Test
    internal func theSavedSearchesLoad() throws {
        let (store, _) = Self.store(["searches": Fixture.searches])
        #expect(store.searches.map(\.name) == ["Big videos", "Invoices"])
        let videos = try #require(store["big videos"]).settings
        #expect(videos.searchFor == "*.mov *.mp4" && videos.searchIn == "/Users/me/Movies;/Volumes/Media")
        #expect(videos.useSpotlight && videos.depth == 2 && !videos.findText && !videos.searchArchives)
        #expect(videos.criteria.dateFrom == Date(timeIntervalSinceReferenceDate: 788_918_400))
        #expect(videos.criteria.dateTo == nil && videos.criteria.olderThan == nil)
        #expect(videos.criteria.notOlderThan == Age(6, .months) && videos.criteria.directory == .no)
        #expect(videos.criteria.size == SizeRule(.greater, 500, .megabytes))
        #expect(!videos.fieldRules.isActive && !videos.duplicates.isActive)
        let notes = try #require(store["invoices"]).settings
        #expect(notes.findText && notes.text == "invoice" && notes.caseSensitive && notes.depth == nil)
        #expect(notes.textOptions.wholeWords && notes.textOptions.encodings == [.utf8, .western])
        #expect(notes.criteria.isEmpty && notes.searchArchives)
        #expect(notes.fieldRules.isActive && !notes.fieldRules.matchAll)
        #expect(notes.fieldRules.rules == [FieldRule("name", .contains, "draft")])
        #expect(
            notes.duplicates == DuplicateOptions(isEnabled: true, sameName: true, sameSize: false, sameContents: true)
        )
        #expect(notes.summary == "*.txt *.md, text \"invoice\", zip, 2x, plugins")
    }

    /// The history of a field loads, newest first.
    @Test
    internal func theHistoriesLoad() {
        let (store, _) = Self.store(["history.searchFor": Fixture.searchForHistory])
        #expect(store.history(.searchFor) == ["*.mov *.mp4", "*.txt"] && store.history(.text).isEmpty)
    }

    /// The searches and the history are stored again in the same shape.
    @Test
    internal func everythingIsSavedInTheSameShape() throws {
        let (store, settings) = Self.store([
            "searches": Fixture.searches, "history.searchFor": Fixture.searchForHistory
        ])
        // Saving a search under its own name replaces it, at the end of the list.
        store.save(try #require(store["Invoices"]))
        store.remember("*.mov *.mp4", in: .searchFor)
        #expect(SettingsJSON.matches(settings.data(forKey: "findFiles.searches"), Fixture.searches))
        #expect(SettingsJSON.matches(settings.data(forKey: "findFiles.history.searchFor"), Fixture.searchForHistory))
    }
}
