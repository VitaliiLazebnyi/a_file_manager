import AFMContracts
import AFMKernel
import AppKit

/// The commands of the file list that need the panel on screen: the quick filter, stepping
/// sideways through the Brief and Thumbnails views, and the colours by file type
/// (spec 03 › Quick search and quick filter, 03 › Brief, 03 › Colours by file type). The
/// options of the lists get their configuration page here as well.
///
/// What is registered here lives in the kernel. It holds neither the kernel nor the panels:
/// the panels hold the kernel, and the kernel holding them back would keep both alive for
/// ever. The panels are held weakly; once they are gone, the commands do nothing.
@MainActor
internal enum PanelShellCommands {
    /// One step to the left in the Brief and Thumbnails views. In those views the key of
    /// "first entry" (←) runs this instead.
    internal static let cursorLeft: CommandID = "afm_CursorLeft"
    /// One step to the right; the key of "last entry" (→) runs this in the grid views.
    internal static let cursorRight: CommandID = "afm_CursorRight"
    /// The dialog that chooses the plugin columns; offered by the header's menu when a plugin
    /// provides it.
    internal static let customColumns: CommandID = "cm_CustomColumnConfig"
    /// Switches the colours by file type on and off.
    internal static let switchColorsByFileType: CommandID = "cm_SwitchColorsByFileType"
    /// Edits the list of colours by file type.
    internal static let defineColorsByFileType: CommandID = "afm_DefineColorsByFileType"
    /// The Show menu's entries about how names are coloured.
    internal static let showColors = MenuSection(.show, order: 35)

    /// Registers the commands, their menu entries and the configuration page with `kernel`;
    /// they act on the source panel of `panels`.
    internal static func register(in kernel: Kernel, panels: PanelCoordinator) {
        let commands = kernel.commands
        let source = { [weak panels] in panels?.sourcePanel }
        commands.register(Command(.quickFilter, "Quick Filter", [Shortcut(.character("s"), .control)])) {
            source()?.showQuickFilter()
        }
        commands.register(Command(cursorLeft, "Cursor Left", runsDuringJobs: true)) {
            source()?.moveCursor(.leftArrow)
        }
        commands.register(Command(cursorRight, "Cursor Right", runsDuringJobs: true)) {
            source()?.moveCursor(.rightArrow)
        }
        let (settings, interaction) = (kernel.settings, kernel.interaction)
        let applySettings = { [weak panels] in panels?.applySettings() }
        commands.register(
            Command(switchColorsByFileType, "Colours by File Type", runsDuringJobs: true),
            enabled: { true },
            checked: { settings.flag(PanelSettings.colorsByTypeKey, default: false) },
            parameterized: { _ in
                let isOn = settings.flag(PanelSettings.colorsByTypeKey, default: false)
                settings.set(!isOn, forKey: PanelSettings.colorsByTypeKey)
                applySettings()
            }
        )
        commands.register(Command(defineColorsByFileType, "Define Colours by File Type…")) {
            if defineColors(settings: settings, interaction: interaction) {
                applySettings()
            }
        }
        kernel.toolbar.setSymbol("line.3.horizontal.decrease.circle", for: .quickFilter)
        kernel.menus.add([.quickFilter], to: .showFilters)
        kernel.menus.add([switchColorsByFileType, defineColorsByFileType], to: showColors)
        kernel.preferences.add(PanelSettings.page { applySettings() })
    }

    /// The list of colours by file type as a text, one entry per line, the first matching entry
    /// deciding (spec 03 › Colours by file type). Lines that cannot be read are reported and
    /// the list is shown again. Returns true when the user changed the settings.
    private static func defineColors(settings: any SettingsStore, interaction: any UserInteraction) -> Bool {
        var text = settings.text(PanelSettings.colorRulesKey, default: PanelSettings.defaultColorRules)
            .replacingOccurrences(of: ";;", with: "\n")
        while let answer = askForColors(text, isOn: settings.flag(PanelSettings.colorsByTypeKey, default: false), interaction) {
            text = answer.text("rules")
            let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if let unreadable = lines.first(where: { !$0.hasPrefix("-") && ColorRule.parse($0).isEmpty }) {
                interaction.inform("This entry cannot be read:", detail: unreadable, style: .warning)
                continue
            }
            settings.set(lines.joined(separator: ";;"), forKey: PanelSettings.colorRulesKey)
            settings.set(answer.flag("enabled"), forKey: PanelSettings.colorsByTypeKey)
            return true
        }
        return false
    }

    /// Shows the list `text` with the switch `isOn` for editing; nil when the user cancelled.
    private static func askForColors(_ text: String, isOn: Bool, _ interaction: any UserInteraction) -> FormValues? {
        let names = ColorRule.namedColors.map(\.name).filter { $0 != "grey" }.joined(separator: ", ")
        let fields: [FormField] = [
            .note(
                "One entry per line: file masks, “=”, a colour. The first entry that matches a name decides. "
                    + "Colours: \(names), or #RRGGBB. A “-” in front of an entry switches it off."
            ),
            .lines("rules", "", text),
            .checkbox("enabled", "Colour names by file type", isOn)
        ]
        return interaction.form("Colours by File Type", detail: "", fields: fields, buttons: ["OK"])
    }
}
