import AFMContracts
import AFMKernel

/// What a test wants from plugins the program does not have yet.
///
/// Buttons for the button bar, someone who runs command lines, a configuration dialog and a
/// Help menu. Main thread only.
@MainActor
internal final class WindowTestPlugin: Plugin {
    /// The plugin's name.
    internal let name = "WindowTest"
    /// The command lines it was handed, in order.
    internal private(set) var ranLines: [String] = []
    /// How often the configuration dialog was asked for.
    internal private(set) var settingsShown = 0
    /// What the parameterised test command was given, in order.
    internal private(set) var parameters: [CommandArgument] = []
    /// Whether it registers the command that runs command lines.
    private let runsLines: Bool

    /// The plugin, which also runs command lines.
    internal convenience init() {
        self.init(runsLines: true)
    }

    /// The plugin; with `runsLines` false nobody runs command lines.
    internal init(runsLines: Bool) {
        self.runsLines = runsLines
    }

    /// Adds the buttons, the commands and the menu entries.
    internal func start(in kernel: Kernel) {
        kernel.toolbar.add(.copy, symbol: "doc.on.doc", group: 1)
        kernel.toolbar.add("cm_NobodyRegisteredThis", symbol: "questionmark", group: 1)
        kernel.toolbar.add(.showHidden, symbol: "eye", group: 2)
        kernel.toolbar.add("cm_NobodyRegisteredThisEither", symbol: "questionmark", group: 3)
        kernel.commands.register(Command(.configuration, "Options…")) { [self] in
            settingsShown += 1
        }
        kernel.commands.register(Command("cm_TestHelp", "Help Index", [.f(1)])) {
            // Nothing to do: the entry only has to be there.
        }
        let parameterized = Command("cm_TestParameter", "Sort ▸ With Parameter")
        kernel.commands.register(parameterized) { [self] (argument: CommandArgument) in
            parameters.append(argument)
        }
        kernel.commands.register(Command("cm_TestSecond", "Sort ▸ Second")) {
            // Nothing to do: the entry only has to be there.
        }
        kernel.menus.add(["cm_TestHelp"], to: .helpTopics)
        kernel.menus.add(["cm_TestParameter", "cm_TestSecond"], to: .commandsTools)
        if runsLines {
            let run = Command(.runCommandLine, "Run Command Line")
            kernel.commands.register(run) { [self] (argument: CommandArgument) in
                ranLines.append(argument.text ?? "?")
            }
        }
    }

    deinit {
        // Nothing to release.
    }
}
