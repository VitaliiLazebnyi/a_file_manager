import AFMKernel
import Foundation
import Testing

/// The command registry: running commands by name, and when it refuses to.
@MainActor
@Suite
internal struct CommandTests {
    /// A plain handler runs as it is; a parameterized one gets the argument it was given, or none.
    @Test
    internal func runsRegisteredCommandsWithTheirArgument() {
        let commands = CommandRegistry()
        var log: [String] = []
        commands.register(Command("plain", "Plain")) { log.append("plain") }
        commands.register(Command("cd", "Change Directory")) { (argument: CommandArgument) in
            log.append("cd \(argument.location?.path ?? argument.text ?? "-")")
        }
        #expect(commands.perform("plain"))
        #expect(commands.perform("cd", .location(URL(fileURLWithPath: "/tmp"))))
        #expect(commands.perform("cd", .text("docs")))
        #expect(commands.perform("cd"))
        #expect(log == ["plain", "cd /tmp", "cd docs", "cd -"])
        #expect(commands.all.map(\.id) == ["plain", "cd"])
        #expect(commands["plain"]?.title == "Plain")
        #expect(CommandArgument.index(3).index == 3)
        #expect(CommandArgument.text("x").location == nil)
    }

    /// Unknown names, a command that is off and a blocked registry run nothing, and each refusal is reported.
    @Test
    internal func rejectsUnknownDisabledAndBlockedCommands() {
        let commands = CommandRegistry()
        var enabled = false
        var runs = 0
        var rejections = 0
        commands.onRejected = { rejections += 1 }
        commands.register(Command("copy", "Copy"), enabled: { enabled }, { runs += 1 })
        #expect(!commands.perform("unknown"))
        #expect(!commands.perform("copy"))
        enabled = true
        #expect(commands.perform("copy"))
        commands.isBlocked = { true }
        #expect(!commands.isEnabled("copy"))
        #expect(!commands.perform("copy"))
        #expect(runs == 1 && rejections == 3)
    }

    /// While a job blocks the registry, a command marked to run during jobs still runs; others do not.
    @Test
    internal func someCommandsRunWhileAJobIsInProgress() {
        let commands = CommandRegistry()
        var views = 0
        commands.register(Command("view", "View", runsDuringJobs: true)) { views += 1 }
        commands.register(Command("delete", "Delete")) {
            // Never run: the registry is blocked.
        }
        commands.isBlocked = { true }
        #expect(commands.isEnabled("view") && commands.perform("view") && views == 1)
        #expect(!commands.isEnabled("delete"))
    }

    /// A command reports itself checked as its own check says; an unknown one is never checked.
    @Test
    internal func checkedState() {
        let commands = CommandRegistry()
        var hidden = false
        commands.register(Command("hidden", "Hidden Files"), checked: { hidden }, { hidden.toggle() })
        #expect(!commands.isChecked("hidden"))
        commands.perform("hidden")
        #expect(commands.isChecked("hidden"))
        #expect(!commands.isChecked("unknown"))
    }
}
