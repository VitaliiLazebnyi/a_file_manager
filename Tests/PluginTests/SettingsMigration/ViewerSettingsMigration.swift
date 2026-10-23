import TestSupport
import Testing

@testable import ViewerPlugin

/// What the Lister remembers of its searches, encodings and print margins, as earlier versions
/// wrote it, loads as it was meant and is written again in the same shape.
@Suite
internal struct ViewerSettingsMigration {
    /// What earlier versions wrote, one fixture per format.
    internal enum Fixture {
        /// The options of the Find dialog as commit 16d647d (2026-10-14) wrote them.
        ///
        /// `viewer.searchOptions`: whole words, backwards, as a regular expression.
        internal static let searchOptions = #"""
            {"wholeWords":true,"caseSensitive":false,"backwards":true,"hex":false,"regex":true}
            """#

        /// What was searched for, as commit 16d647d (2026-10-14) wrote it.
        ///
        /// `viewer.searchHistory`: newest first.
        internal static let searchHistory = #"["needle","Invoice 2026"]"#

        /// The code pages added to the Encoding menu, as commit 16d647d (2026-10-14) wrote them.
        ///
        /// `viewer.userEncodings`: Windows Cyrillic (1251) and Japanese (932).
        internal static let userEncodings = "[1251,932]"

        /// The print margins as commit 16d647d (2026-10-14) wrote them.
        ///
        /// `viewer.printMargins`: left, right, top and bottom in points.
        internal static let printMargins = "[36,36,54,54.5]"
    }

    /// Lister settings on fresh settings holding the fixtures.
    private static func lister() -> (lister: ListerSettings, settings: MemorySettings) {
        let settings = MemorySettings()
        SettingsJSON.store(Fixture.searchOptions, forKey: "viewer.searchOptions", in: settings)
        SettingsJSON.store(Fixture.searchHistory, forKey: "viewer.searchHistory", in: settings)
        SettingsJSON.store(Fixture.userEncodings, forKey: "viewer.userEncodings", in: settings)
        SettingsJSON.store(Fixture.printMargins, forKey: "viewer.printMargins", in: settings)
        return (ListerSettings(settings), settings)
    }

    /// Every value loads as it was written.
    @Test
    internal func everythingLoads() {
        let (lister, _) = Self.lister()
        let options = lister.searchOptions
        #expect(options.wholeWords && !options.caseSensitive && options.backwards && !options.hex && options.regex)
        #expect(lister.searchHistory == ["needle", "Invoice 2026"])
        #expect(lister.userCodePages == [1_251, 932])
        #expect(lister.printMargins == [36, 36, 54, 54.5])
    }

    /// Every value is stored again in the shape it was read in.
    @Test
    internal func everythingIsSavedInTheSameShape() {
        let (lister, settings) = Self.lister()
        lister.searchOptions = lister.searchOptions
        lister.searchHistory = lister.searchHistory
        lister.userCodePages = lister.userCodePages
        lister.printMargins = lister.printMargins
        #expect(SettingsJSON.matches(settings.data(forKey: "viewer.searchOptions"), Fixture.searchOptions))
        #expect(SettingsJSON.matches(settings.data(forKey: "viewer.searchHistory"), Fixture.searchHistory))
        #expect(SettingsJSON.matches(settings.data(forKey: "viewer.userEncodings"), Fixture.userEncodings))
        #expect(SettingsJSON.matches(settings.data(forKey: "viewer.printMargins"), Fixture.printMargins))
    }
}
