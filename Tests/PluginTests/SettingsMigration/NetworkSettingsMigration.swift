import AFMKernel
import Foundation
import NetworkPlugin
import TestSupport
import Testing

/// The saved connections and what the connection dialogs remember, as earlier versions wrote
/// them, load as they were meant and are written again in the same shape.
@MainActor
@Suite
internal struct NetworkSettingsMigration {
    /// What earlier versions wrote, one fixture per format.
    internal enum Fixture {
        /// The saved connections as commit 16d647d (2026-10-14) wrote them.
        ///
        /// `network.connections`: every field is written but `port`, which is left out when it
        /// is the protocol's usual one. Numbers stand for the protocol (3 is SFTP, 0 plain FTP),
        /// the name encoding (1 is UTF-8) and the listing (2 is always LIST). An SFTP server
        /// on port 2222, and an anonymous FTP mirror with a command sent after the login.
        internal static let connections = #"""
            [{"id":"6F1C2B3A-1D2E-4F50-8A9B-0C1D2E3F4A5B","name":"Work server","kind":3,"host":"files.example.com",\#
            "port":2222,"user":"me","anonymous":false,"remoteDirectory":"\/srv\/www",\#
            "localDirectory":"\/Users\/me\/Sites","passive":true,"encoding":1,"listing":0,"initCommands":""},\#
            {"id":"0A1B2C3D-4E5F-4061-8273-94A5B6C7D8E9","name":"Mirror","kind":0,"host":"mirror.example.org",\#
            "user":"","anonymous":true,"remoteDirectory":"\/pub","localDirectory":"","passive":false,"encoding":0,\#
            "listing":2,"initCommands":"SITE UMASK 022"}]
            """#

        /// Connections with fields missing, of the wrong kind, or unknown.
        ///
        /// What a damaged file or another version could hold: only the identifier is needed;
        /// a port that is none is the usual port, a protocol that is no number is FTP.
        internal static let connectionsOtherFields = #"""
            [{"id":"11111111-2222-3333-4444-555555555555","host":"old.example.com","port":70000,"kind":"sftp",\#
            "proxy":"none"}]
            """#

        /// The connection the list starts on, as commit 16d647d (2026-10-14) wrote it.
        ///
        /// `network.lastUsed`: the identifier of a saved connection, as a JSON text.
        internal static let lastUsed = #""6F1C2B3A-1D2E-4F50-8A9B-0C1D2E3F4A5B""#

        /// The addresses of quick connections as commit 16d647d (2026-10-14) wrote them.
        ///
        /// `network.history`: newest first, never with a password.
        internal static let history = #"""
            ["ftp:\/\/mirror.example.org\/pub","sftp:\/\/me@files.example.com:2222\/"]
            """#

        /// Certificates to trust, as the versions before git kept them in the settings.
        ///
        /// `network.trustedCertificates`: fingerprints by host. Nothing believes them any more;
        /// they are erased when the plugin starts.
        internal static let trustedCertificates = #"{"files.example.com":["AA:BB:CC"]}"#
    }

    /// The plugin started on the settings, with passwords in memory. The bench is returned with it: it
    /// owns the kernel the plugin works with.
    private static func started(on settings: any SettingsStore) -> (bench: TestBench, plugin: NetworkPlugin) {
        let memory = MemoryFileSystem()
        let plugin = NetworkPlugin(launchesApplications: false, passwords: MemoryPasswords())
        let bench = TestBench(
            plugins: [plugin],
            fileSystems: [memory],
            left: memory.addDirectory("/A"),
            right: memory.addDirectory("/B"),
            settings: settings
        )
        return (bench, plugin)
    }

    /// Both connections load with every field; the mirror has the usual port of FTP.
    @Test
    internal func theConnectionsLoad() throws {
        let settings = MemorySettings()
        SettingsJSON.store(Fixture.connections, forKey: "network.connections", in: settings)
        let (bench, plugin) = Self.started(on: settings)
        defer { withExtendedLifetime(bench) {} }
        let connections = plugin.connections
        try #require(connections.count == 2)
        let work = connections[0]
        #expect(work.id.uuidString == "6F1C2B3A-1D2E-4F50-8A9B-0C1D2E3F4A5B" && work.name == "Work server")
        #expect(work.kind == .sftp && work.host == "files.example.com" && work.port == 2_222 && work.user == "me")
        #expect(!work.anonymous && work.remoteDirectory == "/srv/www" && work.localDirectory == "/Users/me/Sites")
        #expect(work.passive && work.encoding == .utf8 && work.listing == .automatic && work.initCommands.isEmpty)
        #expect(work.key == ServerKey(scheme: "sftp", host: "files.example.com", port: 2_222))
        let mirror = connections[1]
        #expect(mirror.kind == .ftp && mirror.port == nil && mirror.key.port == 21 && mirror.anonymous)
        #expect(!mirror.passive && mirror.encoding == .automatic && mirror.listing == .list)
        #expect(mirror.initCommands == "SITE UMASK 022" && mirror.remoteDirectory == "/pub")
    }

    /// Fields that are missing or wrong take their usual values; the rest of the list is kept.
    @Test
    internal func connectionsWithOtherFieldsLoad() throws {
        let settings = MemorySettings()
        SettingsJSON.store(Fixture.connectionsOtherFields, forKey: "network.connections", in: settings)
        let (bench, plugin) = Self.started(on: settings)
        defer { withExtendedLifetime(bench) {} }
        let connection = try #require(plugin.connections.first)
        #expect(connection.host == "old.example.com" && connection.port == nil && connection.kind == .ftp)
        #expect(connection.name.isEmpty && connection.user.isEmpty && connection.passive)
        #expect(connection.encoding == .automatic && connection.listing == .automatic)
    }

    /// The last used connection and the quick connections load.
    @Test
    internal func theLastConnectionAndTheHistoryLoad() {
        let settings = MemorySettings()
        SettingsJSON.store(Fixture.lastUsed, forKey: "network.lastUsed", in: settings)
        SettingsJSON.store(Fixture.history, forKey: "network.history", in: settings)
        let store = ConnectionStore(settings: settings, passwords: MemoryPasswords())
        #expect(store.lastUsed?.uuidString == "6F1C2B3A-1D2E-4F50-8A9B-0C1D2E3F4A5B")
        #expect(store.history == ["ftp://mirror.example.org/pub", "sftp://me@files.example.com:2222/"])
    }

    /// The certificates an earlier version trusted are not believed, and are erased.
    @Test
    internal func trustedCertificatesInTheSettingsAreErased() {
        let settings = MemorySettings()
        SettingsJSON.store(Fixture.trustedCertificates, forKey: "network.trustedCertificates", in: settings)
        let (bench, plugin) = Self.started(on: settings)
        defer { withExtendedLifetime(bench) {} }
        let trust = plugin.center.environment.trust
        trust.prepare()
        #expect(!trust.isAccepted("AA:BB:CC", for: "files.example.com"))
        #expect(SettingsJSON.matches(settings.data(forKey: "network.trustedCertificates"), "{}"))
    }

    /// The connections, the last one used and the history are stored again in the same shape.
    @Test
    internal func everythingIsSavedInTheSameShape() throws {
        let settings = MemorySettings()
        SettingsJSON.store(Fixture.connections, forKey: "network.connections", in: settings)
        SettingsJSON.store(Fixture.lastUsed, forKey: "network.lastUsed", in: settings)
        SettingsJSON.store(Fixture.history, forKey: "network.history", in: settings)
        let store = ConnectionStore(settings: settings, passwords: MemoryPasswords())
        store.connections = store.connections
        store.lastUsed = store.lastUsed
        // Connecting again to the newest address leaves the list as it was.
        let newest = try #require(store.history.first)
        store.remember(address: try #require(ServerAddress(newest)))
        #expect(SettingsJSON.matches(settings.data(forKey: "network.connections"), Fixture.connections))
        #expect(SettingsJSON.matches(settings.data(forKey: "network.lastUsed"), Fixture.lastUsed))
        #expect(SettingsJSON.matches(settings.data(forKey: "network.history"), Fixture.history))
    }
}
