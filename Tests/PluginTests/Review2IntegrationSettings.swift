import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// Review round 2, integration: an imported settings file is judged by what the plugins say
/// their keys are (`Kernel.settingsKeys`), not only by words in the keys' names
/// (`cross-requests/archnet-p2.md` item 3).
///
/// The list of servers a password may be sent to without protection,
/// `network.unprotectedPasswordHosts`, has none of those words in its name: a file could plant a
/// host there and take that question away without being asked.
@MainActor
@Suite
internal struct Review2IntegrationSettings {
    /// The folders on disk: the two panels' `A` and `B`, and the settings file to import.
    internal let box: Sandbox
    /// The settings the program keeps, in memory.
    internal let settings = MemorySettings()
    /// The plugin that imports and exports settings files.
    internal let plugin: ConfigurationPlugin
    /// The kernel with the plugin, the disk and the settings.
    internal let bench: TestBench

    /// Starts the plugin and declares the keys as the network and viewer plugins do.
    internal init() throws {
        box = try Sandbox()
        try box.folder("A")
        try box.folder("B")
        plugin = ConfigurationPlugin(
            launchesApplications: false,
            background: nil,
            listFolder: box.url("lists")
        ) { [] }
        bench = TestBench(
            plugins: [plugin],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B"),
            settings: settings
        )
        // What the network plugin says about its keys when it starts.
        bench.kernel.settingsKeys.declare(prefix: "network.")
        bench.kernel.settingsKeys.declare("network.unprotectedPasswordHosts", kind: .trust)
        bench.kernel.settingsKeys.declare("viewer.helper", kind: .runsCode)
    }

    /// The stored value of `key` as text, or nil when it is not set.
    private func stored(_ key: String) -> String? {
        settings.data(forKey: key).flatMap { String(bytes: $0, encoding: .utf8) }
    }

    /// A key its plugin calls trust is shown in the import's form and comes in only when the
    /// user ticks it; an ordinary key comes in as proposed.
    @Test
    internal func aKeyItsPluginCallsTrustIsImportedOnlyWhenTheUserTicksIt() throws {
        let url = box.url("in.json")
        let entries =
            #""network.unprotectedPasswordHosts":["evil.example"],"network.passiveMode":false,"#
            + #""viewer.helper":["/tmp/evil","-x"]"#
        try Data("{\"format\":\"A File Manager settings\",\"version\":1,\"settings\":{\(entries)}}".utf8).write(to: url)

        // Accepted as proposed: the ordinary setting comes in, the trusted servers and what is run do not.
        bench.interaction.formAnswers = [.accept]
        bench.commands.perform("afm_ImportSettings", .location(url))
        let fields = try #require(bench.interaction.forms.last)
        let parts =
            fields.filter { field in
                guard case .checkbox = field.kind else {
                    return false
                }
                return true
            }
            .map(\.key)
        #expect(parts == ["programs", "trust"])
        if case .multilineText(let text)? = fields.first(where: { $0.key == "trust.contents" })?.kind {
            #expect(text.contains("evil.example"))
        } else {
            Issue.record("The servers that would be trusted are not shown")
        }
        #expect(stored("network.passiveMode") == "false")
        #expect(
            settings.data(forKey: "network.unprotectedPasswordHosts") == nil
                && settings.data(forKey: "viewer.helper") == nil
        )

        // Ticked, it comes in.
        bench.interaction.formAnswers = [.values(["trust": .flag(true)])]
        bench.commands.perform("afm_ImportSettings", .location(url))
        #expect(stored("network.unprotectedPasswordHosts") == #"["evil.example"]"#)
        #expect(settings.data(forKey: "viewer.helper") == nil)
    }

    /// The key is connection data, left out of an export like the rest, and only because its
    /// plugin says so.
    @Test
    internal func itIsLeftOutOfAnExportLikeTheOtherConnectionData() throws {
        var schema = try #require(plugin.center).settingsSchema()
        #expect(schema.group(of: "network.unprotectedPasswordHosts", value: ["a"]) == .trust)
        #expect(schema.isConnectionData("network.unprotectedPasswordHosts"))
        #expect(schema.group(of: "network.passiveMode", value: false) == nil)
        // Without the plugin's word the name alone says nothing.
        schema.declaredKind = { _ in nil }
        #expect(schema.group(of: "network.unprotectedPasswordHosts", value: ["a"]) == nil)
    }

    /// The schema's copy of the declarations answers on any thread exactly as the registry
    /// does on the main thread: the key itself first, else the longest family it belongs to.
    @Test
    internal func theSchemaAnswersAsTheRegistryDoesOnAnyThread() async throws {
        let keys = bench.kernel.settingsKeys
        keys.declare(prefix: "findFiles.", kind: .ordinary)
        keys.declare(prefix: "findFiles.history.", kind: .history)
        keys.declare(prefix: "findFiles.history.deep.", kind: .runsCode)
        keys.declare("findFiles.history", kind: .trust)
        keys.declare("findFiles.history.deep.", kind: .connection)
        // A later word wins, for a key and for a family.
        keys.declare("viewer.helper", kind: .history)
        keys.declare(prefix: "findFiles.", kind: .connection)
        let probes = [
            "findFiles.", "findFiles.x", "findFiles.history", "findFiles.history.", "findFiles.history.a",
            "findFiles.history.deep", "findFiles.history.deep.", "findFiles.history.deep.b", "findFilesX",
            "findfiles.x",
            "network.unprotectedPasswordHosts", "network.passiveMode", "network.", "network", "viewer.helper",
            "viewer.helperX", "", "é.findFiles.x"
        ]
        let expected = probes.map { keys.kind(of: $0) }
        let schema = try #require(plugin.center).settingsSchema()
        // Declared after the copy: the schema does not see it.
        keys.declare(prefix: "viewer.", kind: .trust)
        let answered = await Task.detached { probes.map { schema.declaredKind($0) } }.value
        #expect(answered == expected)
        #expect(schema.declaredKind("viewer.other") == nil && keys.kind(of: "viewer.other") == .trust)
    }
}
