import AFMContracts
import AFMKernel
import AppKit

/// The commands of the window around the panels.
///
/// Which bars are shown, how the panels are arranged, and the command line (spec 02 › Showing
/// and hiding regions, 02 › Panel divider and arrangement, 06 › Command line). They are
/// registered like any plugin's commands, so their keys are in the key bindings and they can
/// be put in menus and on the button bar. None of them changes files or panels, so all of them
/// also run while a job is under way. Main thread only.
@MainActor
internal enum WindowCommands {
    /// Pictures for the user who wants these on the button bar; none is proposed as a button.
    private static let symbols: [(command: CommandID, symbol: String)] = [
        (.panelsStacked, "rectangle.split.1x2"), (.panelsEqualWidth, "rectangle.split.2x1"),
        (.focusCommandLine, "terminal"), (.showDriveButtons, "externaldrive"),
        (.showCommandLine, "character.cursor.ibeam"), (.showFunctionKeys, "keyboard")
    ]

    /// Registers the commands with `kernel`, acting on `layout` and on the window `window`
    /// answers.
    ///
    /// `window` answers nil until the window exists; the commands are registered before it,
    /// because it is built from the final key bindings.
    internal static func register(
        in kernel: Kernel,
        layout: WindowLayout,
        window: @escaping () -> MainWindowController?
    ) {
        registerLayoutCommands(in: kernel.commands, layout: layout)
        registerCommandLineCommands(in: kernel.commands, layout: layout, window: window)
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        kernel.commands.register(
            Command(.resetButtonBar, "Reset Button Bar to Default", runsDuringJobs: true),
            enabled: { [weak kernel] in kernel.map { $0.toolbar.hasUserLayout(in: $0.settings) } ?? false },
            { [weak kernel] in kernel.map { $0.toolbar.resetLayout(in: $0.settings) } }
        )
        kernel.menus.add(
            [.showButtonBar, .showDriveButtons, .showCommandLine, .showFunctionKeys, .panelsStacked, .panelsEqualWidth],
            to: .showWindow
        )
        kernel.menus.add(
            [
                .focusCommandLine, .commandLineHistory, .addNameToCommandLine, .addPathAndNameToCommandLine,
                .addPathToCommandLine
            ],
            to: .commandsRun
        )
        kernel.preferences.add(layout.preferencePage())
        for (command, symbol) in symbols {
            kernel.toolbar.setSymbol(symbol, for: command)
        }
    }

    /// Which bars are shown and how the panels are arranged.
    private static func registerLayoutCommands(in commands: CommandRegistry, layout: WindowLayout) {
        for (id, region) in [
            (CommandID.showButtonBar, WindowLayout.Region.buttonBar), (.showDriveButtons, .driveButtons),
            (.showCommandLine, .commandLine), (.showFunctionKeys, .functionKeys)
        ] {
            commands.register(
                Command(id, region.caption, runsDuringJobs: true),
                checked: { layout.isVisible(region) },
                { layout.setVisible(region, !layout.isVisible(region)) }
            )
        }
        commands.register(
            Command(.panelsStacked, "Panels One Above the Other", runsDuringJobs: true),
            checked: { layout.isStacked },
            { layout.isStacked.toggle() }
        )
        commands.register(
            Command(.panelsEqualWidth, "Panels of Equal Size", runsDuringJobs: true),
            checked: { layout.divider == 500 },
            { layout.divider = 500 }
        )
    }

    /// The commands of the command line.
    ///
    /// Using one shows a line that was switched off (spec 02 › Showing and hiding regions: a
    /// hidden command line reappears), except Clear, which has nothing to show.
    private static func registerCommandLineCommands(
        in commands: CommandRegistry,
        layout: WindowLayout,
        window: @escaping () -> MainWindowController?
    ) {
        func line(_ id: CommandID, _ title: String, _ keys: [Shortcut], _ run: @escaping (CommandLineView) -> Void) {
            commands.register(Command(id, title, keys, runsDuringJobs: true)) {
                layout.setVisible(.commandLine, true)
                if let commandLine = window()?.commandLine {
                    run(commandLine)
                }
            }
        }
        // Total Commander has no key for the focus command; Cmd+L is where the Mac has "go to the address".
        line(.focusCommandLine, "Focus Command Line", [.cmd("l")]) { $0.focusField() }
        line(.commandLineHistory, "Command Line History", [.f(8, .option), Shortcut(.downArrow, .control)]) { line in
            line.showHistory()
        }
        line(
            .addNameToCommandLine,
            "Add Name to Command Line",
            [Shortcut(.returnKey, .control), Shortcut(.enter, .control)]
        ) { line in
            line.addCursorItem(withPath: false)
        }
        line(
            .addPathAndNameToCommandLine,
            "Add Name with Path to Command Line",
            [Shortcut(.returnKey, [.control, .shift]), Shortcut(.enter, [.control, .shift])]
        ) { line in
            line.addCursorItem(withPath: true)
        }
        line(.addPathToCommandLine, "Add Path to Command Line", [Shortcut(.character("p"), .control)]) { $0.addPath() }
        line(.previousCommandLine, "Previous Command Line", [Shortcut(.character("e"), .control)]) { $0.recall(1) }
        line(.nextCommandLine, "Next Command Line", []) { $0.recall(-1) }
        commands.register(Command(.clearCommandLine, "Clear Command Line", runsDuringJobs: true)) {
            window()?.commandLine.clear()
        }
    }
}
