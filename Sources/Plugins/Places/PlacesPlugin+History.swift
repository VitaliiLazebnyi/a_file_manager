import AFMContracts
import AFMKernel
import Foundation

/// The directory history: Alt+Down and Alt+Shift+Down, and saving and deleting the histories.
extension PlacesPlugin {
    /// Alt+Down, Alt+Shift+Down and the "Save now" and "Delete now" of the history page.
    internal func registerHistoryCommands(in kernel: Kernel, tracker: DirectoryHistoryTracker) {
        let commands = kernel.commands
        let settings = kernel.settings
        commands.register(Command(.directoryHistory, "Directory History…", [Shortcut(.downArrow, .option)])) {
            [self, unowned kernel] in
            showHistory(
                in: kernel,
                tracker: tracker,
                thinning: settings.flag(Keys.thinning, default: true),
                limited: true,
                selected: nil
            )
        }
        commands.register(
            Command(
                .directoryHistoryUnthinned,
                "Directory History (All Folders)…",
                [Shortcut(.downArrow, [.option, .shift])]
            )
        ) { [self, unowned kernel] in
            showHistory(in: kernel, tracker: tracker, thinning: false, limited: false, selected: nil)
        }
        commands.register(Command(.saveDirectoryHistory, "Save Directory History Now", runsDuringJobs: true)) {
            tracker.save()
        }
        commands.register(Command(.clearDirectoryHistory, "Delete Directory History", runsDuringJobs: true)) {
            tracker.clear()
        }
    }

    /// The "maximum to show" setting under `key`, between 1 and 200; `value` when it is no number.
    private func limit(_ key: String, default value: Int, in kernel: Kernel) -> Int {
        min(
            max(
                Int(kernel.settings.text(key, default: String(value)).trimmingCharacters(in: .whitespaces)) ?? value,
                1
            ),
            200
        )
    }

    /// Alt+Down: the directories the source panel visited, the last one first, and below them
    /// the folders used most often.
    ///
    /// The list comes back after "Remove", so several entries can be cleared in a row.
    ///
    /// The "maximum to show" settings apply to Alt+Down, with or without thinning; the
    /// unthinned list of Alt+Shift+Down shows everything (`limited: false`).
    private func showHistory(
        in kernel: Kernel,
        tracker: DirectoryHistoryTracker,
        thinning: Bool,
        limited: Bool,
        selected: Int?
    ) {
        let panel = kernel.panels.source
        let side = side(of: panel, in: kernel)
        let current = panel.model.directory
        // Also right after the start, before any event came, the list has the current folder.
        tracker.visited(current, on: side)
        let menu = historyMenu(of: tracker, side: side, thinning: thinning, limited: limited, in: kernel)
        let fields = [
            FormField.list(
                "row",
                "",
                menu.titles,
                selected: min(selected ?? menu.selected, max(menu.rows.count - 1, 0))
            )
        ]
        guard
            let answer = kernel.interaction.form(
                "Directory History",
                detail: "",
                fields: fields,
                buttons: ["Go", "Open in New Tab", "Open in Other Panel", "Remove from List"]
            ),
            menu.rows.indices.contains(answer.index("row"))
        else { return }
        let row = menu.rows[answer.index("row")]
        guard let directory = row.directory else {
            // The separator: the list comes back as it was.
            showHistory(in: kernel, tracker: tracker, thinning: thinning, limited: limited, selected: selected)
            return
        }
        switch answer.button {
        case 1:
            _ = panel.tabs.openTab(showing: directory)

        case 2:
            kernel.panels.target.show(directory)

        case 3:
            if case .frequent = row {
                tracker.removeFrequent(directory)
            } else {
                tracker.remove(directory, from: side)
            }
            showHistory(
                in: kernel,
                tracker: tracker,
                thinning: thinning,
                limited: limited,
                selected: answer.index("row")
            )

        default:
            panel.show(directory)
        }
    }

    /// The rows of the history list of `side`, with the frequently used folders when they are shown.
    private func historyMenu(
        of tracker: DirectoryHistoryTracker,
        side: DirectoryHistoryTracker.Side,
        thinning: Bool,
        limited: Bool,
        in kernel: Kernel
    ) -> HistoryMenu {
        let showsFrequent = kernel.settings.flag(Keys.showFrequent, default: true)
        return HistoryMenu(
            history: tracker.history(of: side)
                .shown(
                    thinning: thinning,
                    limit: limited ? limit(Keys.historyShown, default: 26, in: kernel) : nil
                ),
            frequent: showsFrequent
                ? tracker.frequent.top(limited ? limit(Keys.frequentShown, default: 30, in: kernel) : nil) : [],
            current: kernel.panels.source.model.directory,
            displayPath: kernel.fileSystems.displayPath
        )
    }
}
