import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// Settings files: what is known, checked, asked about and written, at the corners the other
/// suites leave.
@Suite internal struct CovConfigSettingsTransfer {
    private let box: Sandbox

    internal init() throws {
        box = try Sandbox()
    }

    /// JSON text of a value.
    private static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys])
    }

    /// The import plan of a file holding `values`, against `current`.
    private static func plan(
        _ values: [String: Any],
        current: [String: Data] = [:],
        knownKeys: [String] = [],
        schema: SettingsSchema = SettingsSchema()
    ) throws -> SettingsImportPlan {
        var archive = SettingsArchive()
        for (key, value) in values { archive.values[key] = try json(value) }
        let checked = try CheckedSettings(archive, schema: schema)
        return SettingsImportPlan(checked, current: current, knownKeys: knownKeys, schema: schema)
    }

    /// What a key's own plugin declares counts before its name: history and connections.
    @Test
    internal func declaredKindsCountBeforeNames() {
        var schema = SettingsSchema()
        schema.declaredKind = { $0 == "viewer.seen" ? .history : ($0 == "network.peers" ? .connection : nil) }
        #expect(schema.isHistory("viewer.seen") && !schema.isHistory("viewer.font"))
        #expect(schema.group(of: "network.peers", value: nil) == .connections)
    }

    /// A tab without a location is no server tab; a key of dots alone names no program.
    @Test
    internal func oddTabsAndKeysAreOrdinary() {
        let schema = SettingsSchema()
        #expect(schema.group(of: "left.tabs", value: ["tabs": [["title": "x"]]]) == nil)
        #expect(schema.group(of: "left.tabs", value: ["tabs": [["location": "sftp://host/"]]]) == .tabs)
        #expect(schema.group(of: "..", value: "x") == nil)
    }

    /// An empty file reads as no data; a value that is no JSON is refused by its name.
    @Test
    internal func emptyFilesAndValuesThatAreNoJSON() throws {
        let empty = try box.file("empty.json", "")
        #expect(try CheckedSettings.read(empty).isEmpty)
        var archive = SettingsArchive()
        archive.values["viewer.font"] = Data("not json".utf8)
        let error = #expect(throws: CheckedSettings.Problem.self) {
            try CheckedSettings(archive, schema: SettingsSchema())
        }
        #expect(error?.errorDescription?.contains("“viewer.font”") == true)
    }

    /// Numbers beyond every sensible size are limited, below as above; booleans are left alone.
    @Test
    internal func numbersAreLimitedBothWays() throws {
        var archive = SettingsArchive()
        archive.values["viewer.sizes"] = try Self.json([1e15, -1e15, 3, true])
        let checked = try CheckedSettings(archive, schema: SettingsSchema())
        #expect(checked.limited == 2)
        let sizes = try #require(checked.objects["viewer.sizes"] as? [Any])
        #expect((sizes[0] as? NSNumber)?.int64Value == 1_000_000_000_000)
        #expect((sizes[1] as? NSNumber)?.int64Value == -1_000_000_000_000)
        #expect((sizes[3] as? Bool) == true)
    }

    /// The visit counters of the frequent folders stay between none and a million; other values pass.
    @Test
    internal func visitCountersAreLimited() throws {
        var archive = SettingsArchive()
        archive.values[SettingsSchema.frequentFoldersKey] = try Self.json([
            "counts": ["a": -5, "b": 5_000_000, "c": 3, "d": true, "e": "x"]
        ])
        archive.values["places.history.other"] = try Self.json(["counts": 1])
        let checked = try CheckedSettings(archive, schema: SettingsSchema())
        let counts = try #require((checked.objects[SettingsSchema.frequentFoldersKey] as? [String: Any])?["counts"])
        let numbers = try #require(counts as? [String: Any])
        #expect(checked.limited == 2)
        #expect((numbers["a"] as? Int) == 0 && (numbers["b"] as? Int) == 1_000_000 && (numbers["c"] as? Int) == 3)
        #expect((numbers["d"] as? Bool) == true && (numbers["e"] as? String) == "x")
    }

    /// A frequent-folders value without counts is taken as it is.
    @Test
    internal func frequentFoldersWithoutCountsPass() throws {
        var archive = SettingsArchive()
        archive.values[SettingsSchema.frequentFoldersKey] = try Self.json(["paths": ["/a"]])
        #expect(try CheckedSettings(archive, schema: SettingsSchema()).limited == 0)
    }

    /// The parts of an import list what they hold: the Start menu with parameters and folders,
    /// separators left out; programs; trusted servers of every shape; connections; the hotlist; tabs.
    @Test
    internal func thePartsListWhatTheyHold() throws {
        let plan = try Self.plan([
            SettingsSchema.startMenuKey: [
                ["title": "Build", "action": ["command": "make", "parameters": "%P", "startPath": "/src"]],
                ["title": "-", "action": [String: Any]()],
                ["title": "Bare"]
            ],
            SettingsSchema.userCommandsKey: [["name": "em_line", "title": "-", "action": ["command": "ls"]]],
            SettingsSchema.symbolsKey: ["em_line": "star"],
            KeyBindings.settingsKey: ["cm_b": [String](), "cm_a": ["f5", "ctrl+x"]],
            "systemTools.editor": "/usr/bin/vi",
            "network.trustedCertificates": ["host.example": "abc"],
            "network.trustedHosts": ["a.example", 7],
            "network.trustNothing": [Any](),
            SettingsSchema.connectionsKey: [["id": "1", "name": "Box", "user": "me", "host": "h"]],
            SettingsSchema.hotlistKey: [
                ["title": "Go", "command": "cm_x", "children": [["name": "Sub", "command": "cd /"]]], 5
            ],
            "right.tabs": [
                "active": 0,
                "tabs": [Self.tab("sftp://h/"), Self.tab("file:///")]
            ]
        ])
        func lines(_ group: SettingsSchema.Group) -> [String] { plan.parts.first { $0.group == group }?.lines ?? [] }
        #expect(
            lines(.commands) == [
                "Start menu “Build”:  make   parameters: %P   in: /src", "Start menu “Bare”:  ", "em_line:  ls"
            ]
        )
        #expect(lines(.keys) == ["cm_a:  f5, ctrl+x", "cm_b:  no key"])
        #expect(lines(.programs) == ["systemTools.editor:  /usr/bin/vi"])
        #expect(
            lines(.trust) == [
                "network.trustNothing", "network.trustedCertificates: host.example", "network.trustedHosts: a.example",
                "network.trustedHosts: "
            ]
        )
        #expect(lines(.connections) == ["Box:  me@h"])
        #expect(lines(.hotlist) == ["Go:  cm_x", "Sub:  cd /"])
        #expect(lines(.tabs) == ["right.tabs:  sftp://h/"])
        #expect(plan.parts.allSatisfy { !$0.title.isEmpty })
    }

    /// A tab as the panels store it.
    private static func tab(_ location: String) -> [String: Any] {
        ["location": location, "sortKey": 0, "descending": false, "showHidden": false, "locked": false]
    }

    /// A value of another type than its check gave it is read as empty.
    @Test
    internal func aValueOfAnotherTypeIsEmpty() {
        #expect(SettingsImportPlan.value("text", or: [[String: Any]]()).isEmpty)
        #expect(SettingsImportPlan.value(["a": ["b"]], or: [String: [String]]()) == ["a": ["b"]])
    }

    /// The summary names at most twelve keys of a kind and counts the others.
    @Test
    internal func theSummaryCutsLongListsOfKeys() throws {
        let values = Dictionary(uniqueKeysWithValues: (0..<14).map { ("viewer.option\($0)", $0 as Any) })
        let summary = try Self.plan(values).summary(fileName: "s.json")
        #expect(summary.contains("14 ordinary settings differ") && summary.contains(", … (2 more)."))
    }

    /// A long part shows its first two hundred lines and says how many more there are.
    @Test
    internal func aLongPartIsCutShort() throws {
        let commands = (0..<250).map { ["title": "Item \($0)", "action": ["command": "x"]] }
        let plan = try Self.plan([SettingsSchema.startMenuKey: commands])
        let lines = try #require(plan.parts.first?.lines)
        #expect(lines.count == 201 && lines.last == "… and 50 more")
    }

    /// A connection that is new gets a number of its own, and the last one used follows it.
    @Test
    internal func aNewConnectionIsRenumberedWithTheLastUsed() throws {
        let plan = try Self.plan([
            SettingsSchema.connectionsKey: [["id": "abc", "name": "Box"], ["name": "No number"]],
            SettingsSchema.lastConnectionKey: "ABC"
        ])
        let stored = try #require(plan.guarded[SettingsSchema.connectionsKey])
        let connections = try #require(try JSONSerialization.jsonObject(with: stored) as? [[String: Any]])
        let new = try #require(connections.first?["id"] as? String)
        #expect(new != "abc" && connections.last?.keys.contains("id") == false)
        let last = try #require(plan.guarded[SettingsSchema.lastConnectionKey])
        #expect(try JSONSerialization.jsonObject(with: last, options: .fragmentsAllowed) as? String == new)
    }

    /// With everything included an export says nothing is left out.
    @Test
    internal func anExportOfEverythingLeavesNothingOut() {
        let all = SettingsExportOptions(includesHistory: true, includesConnections: true)
        #expect(!all.description(count: 3).contains("Left out"))
        #expect(SettingsExportOptions().description(count: 3).contains("Left out"))
    }

    /// The file is written for the user alone; where it cannot be written nothing stays behind.
    @Test
    internal func theFileIsWrittenForTheUserAlone() throws {
        var archive = SettingsArchive()
        archive.values["viewer.font"] = try Self.json("Menlo")
        let file = box.url("out/settings.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try archive.write(to: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(try SettingsArchive(data: Data(contentsOf: file)) == archive)
        // A folder in the way: the temporary file is removed again.
        let blocked = try box.folder("out/blocked.json")
        try box.file("out/blocked.json/inside", "x")
        #expect(throws: (any Error).self) { try archive.write(to: blocked) }
        let left = try FileManager.default.contentsOfDirectory(atPath: box.url("out").path)
        #expect(left.sorted() == ["blocked.json", "settings.json"])
        // No folder to write in.
        #expect(throws: (any Error).self) { try archive.write(to: box.url("missing/settings.json")) }
    }
}
