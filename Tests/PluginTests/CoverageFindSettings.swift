import AFMKernel
import FindFilesPlugin
import Foundation
import TestSupport
import Testing

/// What Find Files keeps in the settings, when part of it cannot be read.
@MainActor
@Suite
internal struct CoverageFindSettings {
    /// A saved search without its settings (written by another version) is left out; the others load.
    @Test
    internal func aDamagedSearchLeavesTheOthers() throws {
        let settings = MemorySettings()
        let store = SearchStore(settings: settings)
        var good = SearchSettings()
        good.searchFor = "*.txt"
        store.save(SavedSearch(name: "Texts", settings: good))
        let saved = try #require(settings.data(forKey: "findFiles.searches"))
        let list = try #require(try JSONSerialization.jsonObject(with: saved) as? [Any])
        let damaged = try JSONSerialization.data(withJSONObject: [["name": "Broken"]] + list)
        settings.set(damaged, forKey: "findFiles.searches")
        #expect(store.searches.map(\.name) == ["Texts"] && store["texts"]?.settings.searchFor == "*.txt")
        store.delete(named: "TEXTS")
        #expect(store.searches.isEmpty)
    }
}
