import AFMKernel
import Foundation
import OSLog
import TestSupport
import Testing

/// What this process logged in one category of the program from about `start` on. (The
/// store's times are coarser than `Date`'s: a second earlier is asked for, and every test
/// looks for text of its own.)
private func logged(in category: String, since start: Date) throws -> [OSLogEntry] {
    let store = try OSLogStore(scope: .currentProcessIdentifier)
    return try store.getEntries(at: store.position(date: start.addingTimeInterval(-1)))
        .filter { entry in
            guard let entry = entry as? any OSLogEntryWithPayload else { return false }
            return entry.subsystem == Log.subsystem && entry.category == category
        }
}

private func messages(in category: String, since start: Date) throws -> [String] {
    try logged(in: category, since: start).compactMap { ($0 as? OSLogEntryLog)?.composedMessage }
}

/// A plugin that does nothing but has a name of its own.
@MainActor private final class NamedPlugin: Plugin {
    let name: String
    init(_ name: String) { self.name = name }
    func start(in _: Kernel) {
        // Nothing to register.
    }
}

/// The program's log: one subsystem, a category per module, and what the kernel says in it.
@Suite(.serialized) @MainActor struct CoreLog {
    @Test func loggersFileUnderTheProgramsSubsystem() throws {
        let start = Date()
        let category = "Core.Test.\(UUID().uuidString)"
        Log.logger(category).notice("A notice \(42, privacy: .public)")
        #expect(Log.subsystem == "local.a-file-manager")
        #expect(try messages(in: category, since: start) == ["A notice 42"])
        // Signposts are recorded only while Instruments listens; outside it they cost nothing.
        let signposter = Log.signposter(category)
        signposter.endInterval("probe", signposter.beginInterval("probe", id: .exclusive))
        #expect(try logged(in: category, since: start).count == 1)
    }

    @Test func startingAndStoppingThePluginsIsLoggedWithTheirNames() throws {
        let start = Date()
        let name = "Probe \(UUID().uuidString)"
        let kernel = Kernel(productName: "Test", settings: MemorySettings(), interaction: ScriptedInteraction())
        kernel.load([NamedPlugin(name), NamedPlugin(name + " 2")])
        kernel.shutdown()
        let said = try messages(in: "Kernel", since: start)
        #expect(said.contains("Started the plugin \(name)") && said.contains("Started the plugin \(name) 2"))
        #expect(said.contains("Stopped 2 plugins"))
    }

    @Test func twoCommandsThatWantTheSameKeyAreABug() throws {
        let start = Date()
        let keys = KeyBindings()
        let key = Shortcut(.character("q"), [.control, .option, .shift])
        keys.bindDefault(key, to: "core.first")
        keys.bindDefault(key, to: "core.first")
        keys.bindDefault(key, to: "core.second")
        #expect(keys.command(for: key) == "core.first" && keys.shortcuts(for: "core.second").isEmpty)
        let faults = try logged(in: "Kernel", since: start).compactMap { $0 as? OSLogEntryLog }
            .filter { $0.level == .fault && $0.composedMessage.contains("core.") }
        #expect(faults.map(\.composedMessage) == ["core.first and core.second both want ctrl+opt+shift+q"])
    }
}
