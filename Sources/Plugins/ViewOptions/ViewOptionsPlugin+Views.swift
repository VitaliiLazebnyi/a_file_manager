import AFMContracts
import AFMKernel
import Foundation

/// The view types of the Show menu and the plugin columns of the Full view.
extension ViewOptionsPlugin {
    /// One view type of the Show menu: its command, key, view and toolbar button.
    private struct ViewChoice {
        let id: CommandID
        let title: String
        let shortcut: Shortcut
        let mode: PanelViewMode
        let symbol: String
        let hint: String
    }

    /// The view types, in the order of the menu and the toolbar.
    private static let viewChoices = [
        ViewChoice(
            id: .viewBrief,
            title: "Brief",
            shortcut: .f(1, .control),
            mode: .brief,
            symbol: "list.bullet",
            hint: "Show only the names, in several columns."
        ),
        ViewChoice(
            id: .viewFull,
            title: "Full",
            shortcut: .f(2, .control),
            mode: .full,
            symbol: "list.dash",
            hint: "Show one row per file, with size, date and attributes."
        ),
        ViewChoice(
            id: .viewThumbnails,
            title: "Thumbnail View",
            shortcut: .f(1, [.control, .shift]),
            mode: .thumbnails,
            symbol: "square.grid.2x2",
            hint: "Show pictures of the files."
        )
    ]

    /// Registers the view commands, their toolbar buttons and Custom Columns.
    internal func registerViews(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        let commands = kernel.commands
        let source = { kernel.panels.source }
        for view in Self.viewChoices {
            let mode = view.mode
            commands.register(
                Command(view.id, view.title, [view.shortcut]),
                checked: { source().viewMode == mode },
                { source().viewMode = mode }
            )
            kernel.toolbar.add(view.id, symbol: view.symbol, group: 60, hint: view.hint)
        }
        commands.register(
            Command(Self.customColumns, "Custom Columns…", [.f(1, .shift)]),
            enabled: { !kernel.columns.all.isEmpty },
            { [self] in chooseColumns(in: kernel) }
        )

        kernel.menus.add(Self.viewChoices.map(\.id) + [Self.customColumns], to: .showViewType)
    }

    /// One checkbox per column the plugins offer.
    ///
    /// The columns that stay keep their order; new ones go to the end, in the order the plugins
    /// registered them.
    private func chooseColumns(in kernel: Kernel) {
        let panel = kernel.panels.source
        let offered = kernel.columns.all
        let fields =
            [FormField.note("Columns shown after the standard ones in the Full view:")]
            + offered.map { FormField.checkbox($0.id, $0.title, panel.extraColumns.contains($0.id)) }
        guard let answer = kernel.interaction.form("Custom Columns", detail: "", fields: fields, buttons: ["OK"]) else {
            return
        }
        let chosen = Set(offered.map(\.id).filter(answer.flag))
        // An id whose plugin is not loaded is not in the dialog and stays as it is.
        let known = Set(offered.map(\.id))
        let kept = panel.extraColumns.filter { chosen.contains($0) || !known.contains($0) }
        let columns = kept + offered.map(\.id).filter { chosen.contains($0) && !kept.contains($0) }
        guard columns != panel.extraColumns else {
            return
        }
        panel.extraColumns = columns
        if !chosen.isEmpty, kernel.settings.flag(Self.columnsSwitchToFullKey, default: true) {
            panel.viewMode = .full
        }
    }
}
