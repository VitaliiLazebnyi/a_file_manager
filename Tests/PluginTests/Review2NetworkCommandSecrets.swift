import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import NetworkPlugin

/// Passwords and trusted certificates of the Net commands (review 2: N033, N083, N084, N086, N100, N104, N105).
@MainActor
@Suite
internal struct Review2NetworkCommandSecrets {
    /// The server, the plugin and the panels.
    private let fixture: Review2NetworkCommandFixture

    /// A fresh server and bench.
    internal init() throws {
        fixture = try Review2NetworkCommandFixture()
    }

    /// The password typed into Quick connect is saved with the connection only when its box stays ticked.
    @Test
    internal func theQuickConnectPasswordIsKeptOnlyWhenTheBoxStaysTicked() throws {
        let (plugin, interaction, passwords) = (fixture.plugin, fixture.interaction, fixture.passwords)
        fixture.server.options.user = "anna"
        fixture.server.options.password = "s3cret-pw"
        for (keeps, name) in [(false, "No password"), (true, "With password")] {
            fixture.quickConnect("ftp://anna:s3cret-pw@\(fixture.address)/pub")
            #expect(fixture.left.model.directory == fixture.url("/pub"))
            // Disconnect, Yes to saving, the details with the box as the round wants it.
            interaction.choiceAnswers = [0]
            interaction.formAnswers = [.values(["name": .text(name), "savePassword": .flag(keeps)])]
            fixture.commands.perform(.ftpDisconnect)
            plugin.waitForStoredSecrets()
            let saved = try #require(plugin.connections.first { $0.name == name })
            #expect(passwords.password(for: PasswordVault.account(of: saved)) == (keeps ? "s3cret-pw" : nil))
        }
        #expect(!passwords.accounts.contains { $0.count == 36 }, "nothing is kept under an identifier alone")
        let saved = try #require(String(bytes: JSONEncoder().encode(plugin.connections), encoding: .utf8))
        #expect(!saved.contains("s3cret"))
    }

    /// A stored password is handed out only for its own host, user and port, and moves with a changed host.
    @Test
    internal func aPasswordBelongsToItsServerAndUser() {
        let passwords = fixture.passwords
        let store = ConnectionStore(settings: MemorySettings(), passwords: passwords)
        var connection = SavedConnection()
        (connection.name, connection.host, connection.user) = ("Work", "files.example.com", "anna")
        store.save(connection)
        store.vault.setPassword("s3cret", for: connection)
        #expect(store.vault.password(for: connection.profile) == "s3cret")

        // A settings file from somebody else: the same identifier, another host. The password
        // was stored for files.example.com and is not handed to the other server.
        var planted = connection
        planted.host = "evil.example.net"
        let foreign = ConnectionStore(settings: MemorySettings(), passwords: passwords)
        foreign.connections = [planted]
        #expect(foreign.vault.password(for: planted.profile) == nil)
        // Nor to another user on the same server, nor on another port.
        planted = connection
        planted.user = "mallory"
        foreign.connections = [planted]
        #expect(foreign.vault.password(for: planted.profile) == nil)
        planted = connection
        planted.port = 2_121
        foreign.connections = [planted]
        #expect(foreign.vault.password(for: planted.profile) == nil)
        // A profile that names a connection the store does not have gets nothing.
        #expect(
            store.vault.password(for: ConnectionProfile(key: connection.key, savedID: UUID(), user: "anna")) == nil
        )

        // When the user changes the host in the dialog, the password follows; that is their own doing.
        var moved = connection
        moved.host = "new.example.com"
        store.save(moved)
        store.vault.carryPassword(from: connection, to: moved, removing: true)
        #expect(store.vault.password(for: moved.profile) == "s3cret")
        store.vault.waitUntilDone()
        #expect(passwords.password(for: PasswordVault.account(of: connection)) == nil)
        store.delete(moved)
        store.vault.waitUntilDone()
        #expect(!passwords.accounts.contains { $0.contains(connection.id.uuidString) })
    }

    /// A password an earlier version kept under the bare identifier is moved once, and never again.
    @Test
    internal func passwordsOfAnEarlierVersionAreMovedOnce() {
        let passwords = fixture.passwords
        var connection = SavedConnection()
        (connection.name, connection.host, connection.user) = ("Old", "files.example.com", "anna")
        let settings = MemorySettings()
        settings.scoped(to: "network").set([connection], forKey: "connections")
        // As an earlier version kept it: under the identifier alone.
        passwords.setPassword("from before", for: connection.id.uuidString)
        let store = ConnectionStore(settings: settings, passwords: passwords)
        #expect(store.vault.password(for: connection.profile) == "from before")
        #expect(passwords.password(for: connection.id.uuidString) == nil)
        #expect(passwords.password(for: PasswordVault.boundAccount) != nil)

        // Later, a settings file that names that identifier for another host, and somebody who
        // put a password under the bare identifier again: nothing is moved a second time.
        passwords.setPassword("bait", for: connection.id.uuidString)
        var planted = connection
        planted.host = "evil.example.net"
        let later = MemorySettings()
        later.scoped(to: "network").set([planted], forKey: "connections")
        let foreign = ConnectionStore(settings: later, passwords: passwords)
        #expect(foreign.vault.password(for: planted.profile) == nil)
    }

    /// Fingerprints in a settings file are removed, not trusted; the ones the user accepts live with the passwords.
    @Test
    internal func certificatesInTheSettingsAreNotBelieved() {
        let (box, passwords) = (fixture.box, fixture.passwords)
        // A settings file that came with a fingerprint for a server: it is not trusted, and it is removed.
        let settings = MemorySettings()
        settings.set(["files.example.com": ["AA:BB"]], forKey: "network.trustedCertificates")
        let plugin = NetworkPlugin(launchesApplications: false, passwords: passwords)
        _ = TestBench(
            plugins: [plugin],
            fileSystems: [LocalFileSystem()],
            left: box.url("local"),
            right: box.url("other"),
            settings: settings
        )
        let trust = plugin.center.environment.trust
        trust.prepare()
        #expect(!trust.isAccepted("AA:BB", for: "files.example.com"))
        #expect((settings.value([String: [String]].self, forKey: "network.trustedCertificates") ?? [:]).isEmpty)

        // What the user accepts for good is kept with the passwords, and found there by the next start.
        let vault = PasswordVault(store: passwords)
        vault.setTrusted(["CC:DD"], for: "Files.Example.com", adding: true)
        vault.setTrusted(["EE:FF"], for: "files.example.com", adding: true)
        #expect(
            vault.trustedCertificates() == ["files.example.com": ["CC:DD", "EE:FF"]]
                && vault.hasTrusted(for: "FILES.example.com")
        )
        // A changed certificate takes the place of the old ones.
        vault.setTrusted(["11:22"], for: "files.example.com", adding: false)
        #expect(vault.trustedCertificates() == ["files.example.com": ["11:22"]])
        let next = NetworkPlugin(launchesApplications: false, passwords: passwords)
        _ = TestBench(
            plugins: [next],
            fileSystems: [LocalFileSystem()],
            left: box.url("local"),
            right: box.url("other"),
            settings: MemorySettings()
        )
        next.center.environment.trust.prepare()
        #expect(next.center.environment.trust.isAccepted("11:22", for: "files.example.com"))
    }

    /// A changed certificate is trusted only with the box that says the new fingerprint was checked.
    @Test
    internal func theDialogForAChangedCertificateNeedsMoreThanAButton() throws {
        let (plugin, interaction) = (fixture.plugin, fixture.interaction)
        let environment = plugin.center.environment
        let profile = ConnectionProfile(key: ServerKey(scheme: "ftps", host: "files.example.com"))
        let old = CertificateInfo(fingerprint: "AA:BB", subject: "files", problem: "self-signed")
        let new = CertificateInfo(fingerprint: "CC:DD", subject: "files", problem: "self-signed")
        // A first visit: the usual question, kept for good when the user says so.
        interaction.formAnswers = [.values(["always": .flag(true)])]
        #expect(environment.askToTrust(profile, old))
        plugin.waitForStoredSecrets()
        #expect(environment.trust.isAccepted("AA:BB", for: "files.example.com"))

        // The certificate changed: another dialog, which says so and shows both fingerprints.
        interaction.formAnswers = [.accept]
        #expect(!environment.askToTrustChanged(profile, new, ["AA:BB"]), "the button alone is no consent")
        #expect(interaction.log.last == "form: The server's certificate has changed!")
        let box = try #require(interaction.forms.last?.first)
        #expect(box.label.contains("checked the new fingerprint"))
        #expect(environment.trust.fingerprints(for: "files.example.com") == ["AA:BB"])
        interaction.formAnswers = [.cancel]
        #expect(!environment.askToTrustChanged(profile, new, ["AA:BB"]))
        // With the box ticked the new one replaces the old, here and where it is stored.
        interaction.formAnswers = [.values(["verified": .flag(true)])]
        #expect(environment.askToTrustChanged(profile, new, ["AA:BB"]))
        plugin.waitForStoredSecrets()
        #expect(environment.trust.fingerprints(for: "files.example.com") == ["CC:DD"])
        #expect(PasswordVault(store: fixture.passwords).trustedCertificates() == ["files.example.com": ["CC:DD"]])
    }

    /// No message, and no stored address proposal, shows a password typed into an address.
    @Test
    internal func noMessageShowsAPassword() {
        let (commands, interaction) = (fixture.commands, fixture.interaction)
        // A mount that fails, and an address that is none.
        commands.perform(.netConnect, .text("smb://anna:s3cret-pw@nas.invalid/share"))
        commands.perform(.netConnect, .text("gopher://anna:s3cret-pw@old.invalid/x"))
        fixture.quickConnect("ftp://anna:s3cret-pw@bad host/")
        #expect(!interaction.log.contains { $0.contains("s3cret") }, "\(interaction.log)")
        #expect(interaction.log.contains("inform: gopher://anna@old.invalid/x is not the address of a server."))
        let server = ServerAddress.removingPassword(from: "smb://anna:s3cret-pw@nas.invalid/share")
        let message = VolumeError(message: "The server \(server) could not be connected: x.")
        #expect(message.localizedDescription.contains("smb://anna@nas.invalid/share"))
        // The stored proposal never holds one either.
        #expect(fixture.settings.text("network.lastServerAddress", default: "") == "smb://anna@nas.invalid/share")
    }
}
