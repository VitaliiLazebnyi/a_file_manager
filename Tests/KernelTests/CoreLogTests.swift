import AFMKernel
import Foundation
import OSLog
import TestSupport
import Testing

/// The program's log: one subsystem, a category per module, and what the kernel says in it.
@MainActor
@Suite(.serialized)
internal struct CoreLogTests {
    /// A plugin that does nothing but has a name of its own.
    private final class NamedPlugin: Plugin {
        let name: String

        init(_ name: String) { self.name = name }

        func start(in _: Kernel) {
            // Nothing to register.
        }

        deinit {
            // Nothing to release.
        }
    }

    /// A logger files its entries under the program's subsystem and the category it was made for.
    @Test
    internal func loggersFileUnderTheProgramsSubsystem() throws {
        let start = Date()
        let category = "Core.Test.\(UUID().uuidString)"
        Log.logger(category).notice("A notice \(42, privacy: .public)")
        #expect(Log.subsystem == "local.a-file-manager")
        #expect(try CoreLogged.messages(in: category, since: start) == ["A notice 42"])
        // Signposts are recorded only while Instruments listens; outside it they cost nothing.
        let signposter = Log.signposter(category)
        signposter.endInterval("probe", signposter.beginInterval("probe", id: .exclusive))
        #expect(try CoreLogged.entries(in: category, since: start).count == 1)
    }

    /// Each plugin that starts is logged with its name, and the stop of all of them with their number.
    @Test
    internal func startingAndStoppingThePluginsIsLoggedWithTheirNames() throws {
        let start = Date()
        let name = "Probe \(UUID().uuidString)"
        let kernel = Kernel(productName: "Test", settings: MemorySettings(), interaction: ScriptedInteraction())
        kernel.load([NamedPlugin(name), NamedPlugin(name + " 2"), NamedPlugin(name + " 3")])
        kernel.shutdown()
        let said = try CoreLogged.messages(in: "Kernel", since: start)
        #expect(said.contains("Started the plugin \(name)") && said.contains("Started the plugin \(name) 2"))
        #expect(said.contains("Stopped 3 plugins"))
    }

    /// Two commands that want one key are a bug: the first keeps it, and a fault says so once.
    @Test
    internal func twoCommandsThatWantTheSameKeyAreABug() throws {
        let start = Date()
        let keys = KeyBindings()
        let key = Shortcut(.character("q"), [.control, .option, .shift])
        keys.bindDefault(key, to: "core.first")
        keys.bindDefault(key, to: "core.first")
        keys.bindDefault(key, to: "core.second")
        #expect(keys.command(for: key) == "core.first" && keys.shortcuts(for: "core.second").isEmpty)
        let faults = try CoreLogged.faults(containing: "core.second", since: start)
        #expect(faults == ["core.first and core.second both want ctrl+opt+shift+q"])
    }
}
