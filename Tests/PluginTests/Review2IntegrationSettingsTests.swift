import AFMContracts
import AFMKernel
@testable import ConfigurationPlugin
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

/// Review round 2, integration: an imported settings file is judged by what the plugins say
/// their keys are (`Kernel.settingsKeys`), not only by words in the keys' names
/// (`cross-requests/archnet-p2.md` item 3). The list of servers a password may be sent to
/// without protection, `network.unprotectedPasswordHosts`, has none of those words in its
/// name: a file could plant a host there and take that question away without being asked.
@MainActor @Suite struct Review2IntegrationSettings {
    let box: Sandbox
    let settings = MemorySettings()
    let plugin: ConfigurationPlugin
    let bench: TestBench

    init() throws {
        box = try Sandbox()
        try box.folder("A")
        try box.folder("B")
        plugin = ConfigurationPlugin(launchesApplications: false, background: nil, listFolder: box.url("lists"), settingsKeys: { [] })
        bench = TestBench(plugins: [plugin], fileSystems: [LocalFileSystem()], left: box.url("A"), right: box.url("B"), settings: settings)
        // What the network plugin says about its keys when it starts.
        bench.kernel.settingsKeys.declare(prefix: "network.")
        bench.kernel.settingsKeys.declare("network.unprotectedPasswordHosts", kind: .trust)
        bench.kernel.settingsKeys.declare("viewer.helper", kind: .runsCode)
    }

    private func stored(_ key: String) -> String? { settings.data(forKey: key).map { String(decoding: $0, as: UTF8.self) } }

    @Test func aKeyItsPluginCallsTrustIsImportedOnlyWhenTheUserTicksIt() throws {
        let url = box.url("in.json")
        let entries = #""network.unprotectedPasswordHosts":["evil.example"],"network.passiveMode":false,"viewer.helper":["/tmp/evil","-x"]"#
        try Data("{\"format\":\"A File Manager settings\",\"version\":1,\"settings\":{\(entries)}}".utf8).write(to: url)

        // Accepted as proposed: the ordinary setting comes in, the trusted servers and what is run do not.
        bench.ui.formAnswers = [.accept]
        bench.commands.perform("afm_ImportSettings", .location(url))
        let fields = try #require(bench.ui.forms.last)
        let parts = fields.filter { if case .checkbox = $0.kind { return true } else { return false } }.map(\.key)
        #expect(parts == ["programs", "trust"])
        if case .multilineText(let text)? = fields.first(where: { $0.key == "trust.contents" })?.kind {
            #expect(text.contains("evil.example"))
        } else {
            Issue.record("The servers that would be trusted are not shown")
        }
        #expect(stored("network.passiveMode") == "false")
        #expect(settings.data(forKey: "network.unprotectedPasswordHosts") == nil && settings.data(forKey: "viewer.helper") == nil)

        // Ticked, it comes in.
        bench.ui.formAnswers = [.values(["trust": .flag(true)])]
        bench.commands.perform("afm_ImportSettings", .location(url))
        #expect(stored("network.unprotectedPasswordHosts") == #"["evil.example"]"#)
        #expect(settings.data(forKey: "viewer.helper") == nil)
    }

    @Test func itIsLeftOutOfAnExportLikeTheOtherConnectionData() {
        var schema = plugin.center!.settingsSchema()
        #expect(schema.group(of: "network.unprotectedPasswordHosts", value: ["a"]) == .trust)
        #expect(schema.isConnectionData("network.unprotectedPasswordHosts"))
        #expect(schema.group(of: "network.passiveMode", value: false) == nil)
        // Without the plugin's word the name alone says nothing.
        schema.declaredKind = { _ in nil }
        #expect(schema.group(of: "network.unprotectedPasswordHosts", value: ["a"]) == nil)
    }
}
