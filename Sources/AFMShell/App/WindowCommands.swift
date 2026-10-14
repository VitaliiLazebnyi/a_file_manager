import AFMContracts
import AFMKernel
import AppKit

/// Command names only the window shell uses (spec 17 › Command catalogue).
extension CommandID {
    static let addNameToCommandLine: CommandID = "cm_AddFileNameToCmdline"
    static let addPathAndNameToCommandLine: CommandID = "cm_AddPathAndFileNameToCmdline"
    static let addPathToCommandLine: CommandID = "cm_AddPathToCmdline"
    static let commandLineHistory: CommandID = "cm_ShowCmdLineHistory"
    static let clearCommandLine: CommandID = "cm_ClearCmdLine"
    static let previousCommandLine: CommandID = "cm_PrevCommand"
    static let nextCommandLine: CommandID = "cm_NextCommand"
    /// Provided by whichever plugin edits the button bar; the bar's context menu offers it.
    static let changeButtonBar: CommandID = "cm_ConfigChangeButtonBar"
    /// Not a Total Commander command: puts back the button bar the plugins proposed.
    static let resetButtonBar: CommandID = "cm_ResetButtonBar"
    /// Provided by the system tools: ejects the drive of the location it is given (the drive
    /// of the source panel without one). The eject buttons of the drive bar and path bar run it.
    static let ejectVolume: CommandID = "afm_EjectVolume"
}

/// The commands of the window around the panels: which bars are shown, how the panels are
/// arranged, and the command line (spec 02 › Showing and hiding regions, 02 › Panel divider and
/// arrangement, 06 › Command line). They are registered like any plugin's commands, so their
/// keys are in the key bindings and they can be put in menus and on the button bar. None of
/// them changes files or panels, so all of them also run while a job is under way.
enum WindowCommands {
    /// `window` answers nil until the window exists; the commands are registered before it,
    /// because it is built from the final key bindings.
    static func register(in kernel: Kernel, layout: WindowLayout, window: @escaping () -> MainWindowController?) {
        let commands = kernel.commands
        func toggle(_ id: CommandID, _ region: WindowLayout.Region) {
            commands.register(Command(id, region.caption, runsDuringJobs: true), checked: { layout.isVisible(region) }) {
                layout.setVisible(region, !layout.isVisible(region))
            }
        }
        toggle(.showButtonBar, .buttonBar)
        toggle(.showDriveButtons, .driveButtons)
        toggle(.showCommandLine, .commandLine)
        toggle(.showFunctionKeys, .functionKeys)
        commands.register(Command(.panelsStacked, "Panels One Above the Other", runsDuringJobs: true), checked: { layout.isStacked }) {
            layout.isStacked.toggle()
        }
        commands.register(Command(.panelsEqualWidth, "Panels of Equal Size", runsDuringJobs: true), checked: { layout.divider == 500 }) {
            layout.divider = 500
        }

        /// A command of the command line; using it shows a line that was switched off
        /// (spec 02 › Showing and hiding regions: a hidden command line reappears).
        func line(_ id: CommandID, _ title: String, _ shortcuts: [Shortcut] = [], _ run: @escaping (CommandLineView) -> Void) {
            commands.register(Command(id, title, shortcuts, runsDuringJobs: true)) {
                layout.setVisible(.commandLine, true)
                if let commandLine = window()?.commandLine { run(commandLine) }
            }
        }
        // Total Commander has no key for the focus command; Cmd+L is where the Mac has "go to the address".
        line(.focusCommandLine, "Focus Command Line", [.cmd("l")]) { $0.focusField() }
        line(.commandLineHistory, "Command Line History", [.f(8, .option), Shortcut(.down, .control)]) { $0.showHistory() }
        line(.addNameToCommandLine, "Add Name to Command Line", [Shortcut(.returnKey, .control), Shortcut(.enter, .control)]) {
            $0.addCursorItem(withPath: false)
        }
        line(.addPathAndNameToCommandLine, "Add Name with Path to Command Line",
             [Shortcut(.returnKey, [.control, .shift]), Shortcut(.enter, [.control, .shift])]) {
            $0.addCursorItem(withPath: true)
        }
        line(.addPathToCommandLine, "Add Path to Command Line", [Shortcut(.character("p"), .control)]) { $0.addPath() }
        line(.previousCommandLine, "Previous Command Line", [Shortcut(.character("e"), .control)]) { $0.recall(1) }
        line(.nextCommandLine, "Next Command Line") { $0.recall(-1) }
        commands.register(Command(.resetButtonBar, "Reset Button Bar to Default", runsDuringJobs: true),
                          enabled: { kernel.toolbar.hasUserLayout(in: kernel.settings) }) {
            kernel.toolbar.setLayout(nil, in: kernel.settings)
        }
        commands.register(Command(.clearCommandLine, "Clear Command Line", runsDuringJobs: true)) { window()?.commandLine.clear() }

        kernel.menus.add([.showButtonBar, .showDriveButtons, .showCommandLine, .showFunctionKeys, .panelsStacked, .panelsEqualWidth],
                         to: .showWindow)
        kernel.menus.add([.focusCommandLine, .commandLineHistory, .addNameToCommandLine, .addPathAndNameToCommandLine, .addPathToCommandLine],
                         to: .commandsRun)
        kernel.preferences.add(layout.preferencePage())
        // Pictures for the user who wants these on the button bar; none is proposed as a button.
        let symbols: [(CommandID, String)] = [
            (.panelsStacked, "rectangle.split.1x2"), (.panelsEqualWidth, "rectangle.split.2x1"), (.focusCommandLine, "terminal"),
            (.showDriveButtons, "externaldrive"), (.showCommandLine, "character.cursor.ibeam"), (.showFunctionKeys, "keyboard"),
        ]
        for (command, symbol) in symbols { kernel.toolbar.setSymbol(symbol, for: command) }
    }
}
