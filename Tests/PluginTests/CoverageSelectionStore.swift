import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import SelectionPlugin

/// What the Mark menu keeps between sessions, read back when part of it is damaged.
@Suite
internal struct CoverageSelectionStore {
    /// One saved type that does not read (written by another version, or edited by hand)
    /// leaves the others: the list does not empty out.
    @Test
    internal func aDamagedTypeLeavesTheOthers() throws {
        let settings = MemorySettings()
        let store = SelectionStore(settings: settings)
        store.save(SelectionType(name: "Pictures", mask: "*.jpg"))
        store.save(SelectionType(name: "Texts", mask: "*.txt"))
        let key = "selection.types"
        let saved = try #require(settings.data(forKey: key))
        var list = try #require(try JSONSerialization.jsonObject(with: saved) as? [Any])
        list.insert(["name": 7, "kind": "nonsense"], at: 1)
        settings.set(try JSONSerialization.data(withJSONObject: list), forKey: key)
        #expect(store.types.map(\.name) == ["Pictures", "Texts"])
        #expect(store.type(named: "texts")?.mask == "*.txt")
        // A value that is no list at all reads as no types.
        settings.set(Data("{}".utf8), forKey: key)
        #expect(store.types.isEmpty)
    }
}
