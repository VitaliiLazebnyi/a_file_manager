import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The options of the file lists and the colours by file type, as read from the settings
/// (spec 03 › Colours by file type, 03 › View types).
@MainActor
@Suite
internal struct PanelSettingsTests {
    /// Entries are read from text, one per line or separated by `;;`; what cannot be read and
    /// what is switched off with `-` is left out; the first entry that matches decides.
    @Test
    internal func colourEntriesAreReadFromText() {
        let rules = ColorRule.parse(
            "*.zip *.gz = purple\n-.tmp = red\nnonsense\n*.swift=#FF8000;;*.md = nocolour;;* = gray;; = red"
        )
        #expect(rules.count == 3)
        #expect(ColorRule.color(for: "a.GZ", in: rules) == .systemPurple)
        #expect(
            ColorRule.color(for: "a.swift", in: rules)
                == NSColor(srgbRed: 1, green: CGFloat(0x80) / 255, blue: 0, alpha: 1)
        )
        #expect(ColorRule.color(for: "a.txt", in: rules) == .systemGray)
        #expect(
            ColorRule.color(for: "a.txt", in: Array(rules.prefix(2))) == nil
                && ColorRule.color(for: "a.md", in: []) == nil
        )
        #expect(ColorRule.color(named: "#12345") == nil && ColorRule.color(named: " Red ") == .systemRed)
        #expect(ColorRule.color(named: "#GGGGGG") == nil && ColorRule.color(named: "grey") == .systemGray)
        #expect(ColorRule.parse(PanelSettings.defaultColorRules).count == 2)
    }

    /// The options start as declared, follow the settings, and keep to their ranges.
    @Test
    internal func theOptionsOfTheListsComeFromTheSettings() {
        let store = MemorySettings()
        var settings = PanelSettings(from: store)
        #expect(settings.briefWidthLimit == 200 && settings.thumbnailSide == 96 && settings.confirmsDrops)
        #expect(settings.colorRules.isEmpty && PanelSettings().thumbnailSide == 96)
        store.set(false, forKey: PanelSettings.limitsBriefWidthKey)
        store.set(3, forKey: PanelSettings.thumbnailSizeKey)
        store.set(false, forKey: PanelSettings.confirmsDropsKey)
        store.set(true, forKey: PanelSettings.colorsByTypeKey)
        settings = PanelSettings(from: store)
        #expect(settings.briefWidthLimit == nil && settings.thumbnailSide == 192 && !settings.confirmsDrops)
        #expect(settings.colorRules.count == 2)
        store.set(99, forKey: PanelSettings.thumbnailSizeKey)
        store.set(true, forKey: PanelSettings.limitsBriefWidthKey)
        store.set("12", forKey: PanelSettings.briefWidthLimitKey)
        #expect(PanelSettings(from: store).thumbnailSide == 256 && PanelSettings(from: store).briefWidthLimit == 60)
        store.set("wide", forKey: PanelSettings.briefWidthLimitKey)
        store.set(-4, forKey: PanelSettings.thumbnailSizeKey)
        #expect(PanelSettings(from: store).briefWidthLimit == 200 && PanelSettings(from: store).thumbnailSide == 64)
        #expect(PanelSettings.page {}.preferences.count == 6 && PanelSettings.page {}.title == "File Panels")
    }

    /// The looks of a panel are remembered in a form that names its layout; an unknown layout
    /// is the Full view.
    @Test
    internal func theLooksOfAPanelNameTheirLayout() {
        var state = PanelViewState()
        #expect(state.viewMode == .full && state.extraColumns.isEmpty && state.columnWidths.isEmpty)
        state.mode = PanelViewMode.thumbnails.rawValue
        #expect(state.viewMode == .thumbnails)
        state.mode = 99
        #expect(state.viewMode == .full && PanelViewState.keys == ["left.view", "right.view"])
    }
}
