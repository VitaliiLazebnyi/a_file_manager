import AFMContracts
import AFMKernel
import AppKit

/// The commands of the file list that need the panel on screen: the quick filter, stepping
/// sideways through the Brief and Thumbnails views, and the colours by file type
/// (spec 03 › Quick search and quick filter, 03 › Brief, 03 › Colours by file type). The
/// options of the lists get their configuration page here as well.
@MainActor
enum PanelShellCommands {
    /// One step to the left or right in the Brief and Thumbnails views. In those views the
    /// keys of "first entry" and "last entry" (← and →) run these instead.
    static let cursorLeft: CommandID = "afm_CursorLeft"
    static let cursorRight: CommandID = "afm_CursorRight"
    /// The dialog that chooses the plugin columns; offered by the header's menu when a plugin
    /// provides it.
    static let customColumns: CommandID = "cm_CustomColumnConfig"
    static let switchColorsByFileType: CommandID = "cm_SwitchColorsByFileType"
    static let defineColorsByFileType: CommandID = "afm_DefineColorsByFileType"

    /// The Show menu's entries about how names are coloured.
    static let showColors = MenuSection(.show, order: 35)

    static func register(in kernel: Kernel, panels: PanelCoordinator) {
        let commands = kernel.commands
        let source = { panels.sourcePanel }

        commands.register(Command(.quickFilter, "Quick Filter", [Shortcut(.character("s"), .control)])) {
            source().showQuickFilter()
        }
        commands.register(Command(cursorLeft, "Cursor Left", runsDuringJobs: true)) { source().moveCursor(.left) }
        commands.register(Command(cursorRight, "Cursor Right", runsDuringJobs: true)) { source().moveCursor(.right) }

        let settings = kernel.settings
        commands.register(
            Command(switchColorsByFileType, "Colours by File Type", runsDuringJobs: true),
            checked: { settings.flag(PanelSettings.colorsByTypeKey, default: false) }
        ) {
            settings.set(
                !settings.flag(PanelSettings.colorsByTypeKey, default: false), forKey: PanelSettings.colorsByTypeKey)
            panels.applySettings()
        }
        commands.register(Command(defineColorsByFileType, "Define Colours by File Type…")) {
            defineColors(in: kernel, panels: panels)
        }

        kernel.toolbar.setSymbol("line.3.horizontal.decrease.circle", for: .quickFilter)
        kernel.menus.add([.quickFilter], to: .showFilters)
        kernel.menus.add([switchColorsByFileType, defineColorsByFileType], to: showColors)
        kernel.preferences.add(PanelSettings.page { panels.applySettings() })
    }

    /// The list of colours by file type as a text, one entry per line, the first matching entry
    /// deciding (spec 03 › Colours by file type). Lines that cannot be read are reported and
    /// the list is shown again.
    private static func defineColors(in kernel: Kernel, panels: PanelCoordinator) {
        let settings = kernel.settings
        var text = settings.text(PanelSettings.colorRulesKey, default: PanelSettings.defaultColorRules)
            .replacingOccurrences(of: ";;", with: "\n")
        let names = ColorRule.namedColors.map(\.name).filter { $0 != "grey" }.joined(separator: ", ")
        while true {
            let fields: [FormField] = [
                .note(
                    "One entry per line: file masks, “=”, a colour. The first entry that matches a name decides. "
                        + "Colours: \(names), or #RRGGBB. A “-” in front of an entry switches it off."),
                .lines("rules", "", text),
                .checkbox(
                    "enabled", "Colour names by file type",
                    settings.flag(PanelSettings.colorsByTypeKey, default: false))
            ]
            guard let answer = kernel.ui.form("Colours by File Type", detail: "", fields: fields, buttons: ["OK"])
            else { return }
            text = answer.text("rules")
            let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter {
                !$0.isEmpty
            }
            let unreadable = lines.filter { !$0.hasPrefix("-") && ColorRule.parse($0).isEmpty }
            if let first = unreadable.first {
                kernel.ui.inform("This entry cannot be read:", detail: first, style: .warning)
                continue
            }
            settings.set(lines.joined(separator: ";;"), forKey: PanelSettings.colorRulesKey)
            settings.set(answer.flag("enabled"), forKey: PanelSettings.colorsByTypeKey)
            panels.applySettings()
            return
        }
    }
}
