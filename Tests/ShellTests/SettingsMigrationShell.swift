import AFMContracts
import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import AFMShell

/// Settings of the shell written by earlier versions: the panels' views, the colours by file
/// type, the button bar's lines and the window's layout load as they were meant, and are
/// written again in the same shape.
@MainActor
@Suite
internal struct SettingsMigrationShell {
    /// What earlier versions wrote, one fixture per format.
    internal enum Fixture {
        /// The view of a panel as commit 16d647d (2026-10-14) wrote it.
        ///
        /// `left.view`: the view (1 is Brief), the plugin columns in order and the width of
        /// each column in points by its identifier; a plugin column's starts with `+`.
        internal static let view = #"""
            {"mode":1,"extraColumns":["upper","length"],"columnWidths":{"name":240,"size":90.5,"+length":61}}
            """#

        /// The colours by file type as the versions before git wrote them.
        ///
        /// `panel.colorRules`: one entry per line, `masks = colour`; a `-` in front switches
        /// an entry off. Archives purple, applications green, temporary files not coloured.
        internal static let colorRulesInLines = #""*.zip *.gz = purple\n*.app = green\n-*.tmp = red""#

        /// The colours by file type as commit 16d647d (2026-10-14) wrote them.
        ///
        /// The same entries joined by `;;`, so that the text fits a one-line field; a colour
        /// may also be `#RRGGBB`.
        internal static let colorRules = #""*.zip *.gz = purple;;*.app = #00FF00""#

        /// Each window setting as commit 16d647d (2026-10-14) wrote it, by key.
        ///
        /// No button bar, the drive buttons shown, the panels one above the other with the
        /// upper one taking 62 %, the right panel the source, the window's frame in the form
        /// `NSWindow` reads, not in full screen, "work" after the title, two command lines
        /// run, and medium pictures on the button bar (1).
        internal static let window: [String: String] = [
            "window.showButtonBar": "false",
            "window.showDriveButtons": "true",
            "window.panelsStacked": "true",
            "window.divider": "620",
            "window.sourcePanel": #""right""#,
            "window.frame": #""100 200 1200 800 0 0 1920 1080 ""#,
            "window.fullScreen": "false",
            "window.titleExtraText": #""$work""#,
            "window.commandLineHistory": #"["ls -la","make test"]"#,
            "window.buttonBarIconSize": "1"
        ]
    }

    /// Stored data in one canonical form, sorted keys and no spacing; nil when it is no JSON.
    ///
    /// Written out, `true` and `1` stay apart, which comparing the objects would not keep.
    internal static func canonical(_ data: Data?) -> Data? {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys])
    }

    /// Whether the stored value holds the same JSON as the fixture, whatever the order of the
    /// keys and the spacing.
    internal static func matches(_ data: Data?, _ fixture: String) -> Bool {
        guard let stored = canonical(data) else {
            return false
        }
        return stored == canonical(Data(fixture.utf8))
    }

    /// Settings holding the fixtures under their keys, byte for byte.
    internal static func settings(_ fixtures: [String: String]) -> MemorySettings {
        let settings = MemorySettings()
        for (key, fixture) in fixtures {
            settings.set(Data(fixture.utf8) as Data?, forKey: key)
        }
        return settings
    }

    /// The view of a panel loads with its mode, columns and widths, and is written back as it was.
    @Test
    internal func theViewOfAPanelLoads() throws {
        let settings = Self.settings(["left.view": Fixture.view])
        let view = try #require(settings.value(PanelViewState.self, forKey: "left.view"))
        #expect(view.viewMode == .brief && view.extraColumns == ["upper", "length"])
        #expect(view.columnWidths == ["name": 240, "size": 90.5, "+length": 61])
        settings.set(view, forKey: "left.view")
        #expect(Self.matches(settings.data(forKey: "left.view"), Fixture.view))
    }

    /// Colours written one entry per line load as they did; the switched-off entry stays off.
    @Test
    internal func coloursInLinesLoad() {
        let settings = Self.settings([
            PanelSettings.colorRulesKey: Fixture.colorRulesInLines, PanelSettings.colorsByTypeKey: "true"
        ])
        let rules = PanelSettings(from: settings).colorRules
        #expect(rules.map(\.maskText) == ["*.zip *.gz", "*.app"] && rules.map(\.colorText) == ["purple", "green"])
        #expect(ColorRule.color(for: "a.gz", in: rules) == .systemPurple)
        #expect(ColorRule.color(for: "Mail.app", in: rules) == .systemGreen)
        #expect(ColorRule.color(for: "x.tmp", in: rules) == nil)
    }

    /// Colours joined by `;;` load, a colour given by its number too.
    @Test
    internal func coloursJoinedLoad() {
        let settings = Self.settings([
            PanelSettings.colorRulesKey: Fixture.colorRules, PanelSettings.colorsByTypeKey: "true"
        ])
        let rules = PanelSettings(from: settings).colorRules
        #expect(rules.map(\.maskText) == ["*.zip *.gz", "*.app"])
        #expect(ColorRule.color(for: "Mail.app", in: rules) == NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
    }

    /// A button bar of one line is one line with two groups, and is written back as it was;
    /// one with lines keeps them.
    @Test
    internal func theButtonBarKeepsItsLines() {
        _ = NSApplication.shared
        let settings = Self.settings([ToolbarRegistry.settingsKey: #"["cm_Copy","","cm_Delete"]"#])
        let kernel = Kernel(productName: "Test", settings: settings, ui: ScriptedInteraction())
        let scratch = ScratchPasteboard()
        kernel.load(CorePlugins.make(pasteboard: scratch.pasteboard))
        defer { kernel.shutdown() }
        let layout = ButtonBarView.entries(of: kernel.toolbar.layout(from: settings), commands: kernel.commands)
        let bar = ButtonBarArrangement(entries: layout.map { $0?.command })
        #expect(bar.lines == [[[.copy], [.delete]]])
        kernel.toolbar.setLayout(bar.entries, in: settings)
        #expect(Self.matches(settings.data(forKey: ToolbarRegistry.settingsKey), #"["cm_Copy","","cm_Delete"]"#))
        let lines = ButtonBarArrangement(entries: [.copy, ToolbarRegistry.lineBreak, .delete])
        #expect(lines.lines == [[[.copy]], [[.delete]]])
    }

    /// The window's settings load: what is shown, the arrangement, the frame and the title.
    @Test
    internal func theWindowSettingsLoad() {
        let settings = Self.settings(Fixture.window)
        let layout = WindowLayout(settings: settings)
        #expect(!layout.isVisible(.buttonBar) && layout.isVisible(.driveButtons) && layout.isVisible(.commandLine))
        #expect(layout.isStacked && layout.divider == 620 && layout.sourceIsRight && !layout.isFullScreen)
        #expect(layout.frame == "100 200 1200 800 0 0 1920 1080 ")
        #expect(
            WindowLayout.title(productName: "A File Manager", version: "1.0", extra: layout.titleExtra)
                == "A File Manager 1.0 work"
        )
        #expect(CommandLineHistory(settings: settings).entries == ["ls -la", "make test"])
        #expect(BarButton.iconSize(from: settings) == 20)
    }

    /// The window's settings are written back as they were: the options through their page,
    /// the rest by what changes them.
    @Test
    internal func theWindowSettingsAreSavedInTheSameShape() {
        let settings = Self.settings(Fixture.window)
        let layout = WindowLayout(settings: settings)
        for preference in layout.preferencePage().preferences {
            settings.set(settings.value(of: preference), for: preference)
        }
        layout.divider = 500
        layout.divider = 620
        layout.sourceIsRight = layout.sourceIsRight
        layout.frame = layout.frame
        layout.isFullScreen = layout.isFullScreen
        CommandLineHistory(settings: settings).add("ls -la")
        for (key, fixture) in Fixture.window.sorted(by: { $0.key < $1.key }) {
            #expect(Self.matches(settings.data(forKey: key), fixture), "\(key)")
        }
    }
}
