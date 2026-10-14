import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import SelectionPlugin

/// The selection types and the masks of Select group, as earlier versions wrote them, load as
/// they were meant and are written again in the same shape.
@Suite
internal struct SelectionSettingsMigration {
    /// What earlier versions wrote, one fixture per format.
    internal enum Fixture {
        /// The selection types as commit 16d647d (2026-10-14) wrote them.
        ///
        /// `selection.types`: a mask with conditions, under a name; limits that are not set are
        /// left out, dates are seconds since 2001-01-01 and choices are numbers. "Big logs":
        /// files (`kind` 1) of 1 MB or more, changed since 2026-01-01 and in the last 30 days,
        /// not hidden (`hidden` 2). "Links": folders (2) that are links (1).
        internal static let types = #"""
            [{"name":"Big logs","mask":"*.log","kind":1,"minSize":1048576,"modifiedFrom":788918400,\#
            "notOlderThanDays":30,"hidden":2,"links":0},{"name":"Links","mask":"*","kind":2,"hidden":0,"links":1}]
            """#

        /// The masks of Select group as commit 16d647d (2026-10-14) wrote them.
        ///
        /// `selection.maskHistory`: newest first.
        internal static let maskHistory = #"["*.txt","*.jpg *.png"]"#
    }

    /// A store on fresh settings holding the fixtures under their keys.
    private static func store(_ fixtures: [String: String]) -> (store: SelectionStore, settings: MemorySettings) {
        let settings = MemorySettings()
        for (key, fixture) in fixtures {
            SettingsJSON.store(fixture, forKey: "selection." + key, in: settings)
        }
        return (SelectionStore(settings: settings), settings)
    }

    /// Both types load with their conditions; what was not set stays unset.
    @Test
    internal func theSelectionTypesLoad() throws {
        let (store, _) = Self.store(["types": Fixture.types])
        #expect(store.types.map(\.name) == ["Big logs", "Links"])
        let logs = try #require(store.type(named: "big LOGS"))
        #expect(logs.mask == "*.log" && logs.kind == .files && logs.minSize == 1_048_576 && logs.maxSize == nil)
        #expect(logs.modifiedFrom == Date(timeIntervalSinceReferenceDate: 788_918_400) && logs.modifiedTo == nil)
        #expect(logs.notOlderThanDays == 30 && logs.hidden == .no && logs.links == .any)
        let links = try #require(store.type(named: "Links"))
        #expect(links.mask == "*" && links.kind == .folders && links.hidden == .any && links.links == .yes)
        #expect(links.minSize == nil && links.modifiedFrom == nil && links.notOlderThanDays == nil)
    }

    /// The masks load, newest first.
    @Test
    internal func theMaskHistoryLoads() {
        let (store, _) = Self.store(["maskHistory": Fixture.maskHistory])
        #expect(store.history == ["*.txt", "*.jpg *.png"])
    }

    /// Both are stored again in the shape they were read in.
    ///
    /// Saving a type under its own name replaces it in place; using the newest mask again
    /// leaves the history as it was.
    @Test
    internal func everythingIsSavedInTheSameShape() throws {
        let (store, settings) = Self.store(["types": Fixture.types, "maskHistory": Fixture.maskHistory])
        store.save(try #require(store.type(named: "Big logs")))
        store.remember("*.txt")
        #expect(SettingsJSON.matches(settings.data(forKey: "selection.types"), Fixture.types))
        #expect(SettingsJSON.matches(settings.data(forKey: "selection.maskHistory"), Fixture.maskHistory))
    }
}
