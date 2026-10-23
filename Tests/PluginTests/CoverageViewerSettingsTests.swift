import AFMKernel
import TestSupport
import Testing

@testable import ViewerPlugin

/// The Lister's options as the settings store keeps them: values that are out of range or not
/// numbers, the image and player options, and the fonts.
@Suite
internal struct CoverageViewerSettingsTests {
    /// A width that is not a number falls back to its default.
    @Test
    internal func aWidthThatIsNoNumberIsTheDefault() {
        let store = MemorySettings()
        store.set("wide", forKey: "viewer.binaryWidth")
        store.set(" 120 ", forKey: "viewer.tabWidth")
        let settings = ListerSettings(store)
        #expect(settings.binaryWidth == 75)
        #expect(settings.tabWidth == 64)
    }

    /// The image options and the player's volume are kept; the volume stays within 0…1, and a
    /// fit the viewer does not know is no fit.
    @Test
    internal func imageAndPlayerOptionsAreKept() {
        let store = MemorySettings()
        let settings = ListerSettings(store)
        #expect(settings.imageFit == .actualSize && !settings.centersImages && settings.playerVolume == 1)
        settings.imageFit = .largerOnly
        settings.centersImages = true
        settings.playerVolume = 1.5
        #expect(settings.imageFit == .largerOnly && settings.centersImages && settings.playerVolume == 1)
        settings.playerVolume = 0.25
        #expect(ListerSettings(store).playerVolume == 0.25)
        store.set(7, forKey: "viewer.fitImages")
        #expect(settings.imageFit == .actualSize)
    }

    /// A font is a name and a size; the size is kept within 6…96, and an empty name or a size
    /// that is no number gives the defaults.
    @Test
    internal func fontsAreANameAndASize() {
        let store = MemorySettings()
        let settings = ListerSettings(store)
        #expect(settings.font(.variable).name == nil && settings.font(.variable).size == 13)
        #expect(settings.font(.ansi).name == nil && settings.font(.ansi).size == 12)
        store.set("Menlo, 14", forKey: "viewer.fixedFont")
        store.set("Helvetica, 200", forKey: "viewer.variableFont")
        #expect(settings.font(.ascii).name == "Menlo" && settings.font(.ascii).size == 14)
        #expect(settings.font(.variable).name == "Helvetica" && settings.font(.variable).size == 96)
        store.set("  , 14", forKey: "viewer.fixedFont")
        #expect(settings.font(.ansi).name == nil && settings.font(.ansi).size == 14)
        store.set("Courier, big", forKey: "viewer.fixedFont")
        #expect(settings.font(.ansi).name == "Courier" && settings.font(.ansi).size == 12)
    }
}
