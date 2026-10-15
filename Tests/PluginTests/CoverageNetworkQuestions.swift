import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// The questions the connections ask the user through the plugin, asked directly.
@MainActor
@Suite
internal struct CoverageNetworkQuestions {
    private let fixture: CoverageNetworkBench

    private var scripted: ScriptedInteraction { fixture.scripted }

    /// A fresh bench.
    internal init() throws {
        fixture = try CoverageNetworkBench()
    }

    /// A connection named `name` for `user` on the test server, saved through the dialog.
    private func save(_ name: String, user: String, anonymous: Bool) -> SavedConnection? {
        let details: [String: FormValues.Value] = [
            "name": .text(name), "host": .text(fixture.address), "user": .text(user), "anonymous": .flag(anonymous)
        ]
        scripted.formAnswers = [.values([:], button: 1), .values(details), .cancel]
        fixture.commands.perform(.ftpConnect)
        return fixture.plugin.connections.first { $0.name == name }
    }

    /// A saved connection is offered to keep the password, and the server's complaint is shown.
    @Test
    internal func aSavedConnectionOffersToKeepThePassword() {
        let profile = ConnectionProfile(key: fixture.key, savedID: UUID(), user: "anna")
        scripted.formAnswers = [.values(["password": .text("pw")])]
        let answer = fixture.environment.askCredentials(profile, "530 Login incorrect")
        #expect(answer?.user == "anna" && answer?.password == "pw" && answer?.remember == true)
        #expect(scripted.forms.last?.contains { $0.key == "save" } == true)
        // Without a user name there is nothing to log in with.
        scripted.formAnswers = [.values(["user": .text("")])]
        #expect(fixture.environment.askCredentials(profile, "") == nil)
    }

    /// A password the server accepted is kept for the saved connection it belongs to.
    @Test
    internal func anAcceptedPasswordIsKeptForItsConnection() async throws {
        let open = try #require(save("Open", user: "", anonymous: false))
        let guest = try #require(save("Guest", user: "ftp", anonymous: true))
        let bob = try #require(save("Bob", user: "bob", anonymous: false))
        let remember = fixture.environment.rememberPassword
        remember(ConnectionProfile(key: fixture.key, savedID: open.id, user: "anna"), "anna-pw")
        remember(ConnectionProfile(key: fixture.key, savedID: guest.id, user: "anna"), "guest-pw")
        remember(ConnectionProfile(key: fixture.key, savedID: bob.id, user: "anna"), "bob-pw")
        remember(ConnectionProfile(key: fixture.key, user: "anna"), "nobody-pw")
        #expect(await fixture.settle { fixture.plugin.connections.first { $0.id == open.id }?.user == "anna" })
        fixture.plugin.waitForStoredSecrets()
        // The empty user name was filled in, and the password kept under it.
        let filled = fixture.plugin.connections.first { $0.id == open.id }
        #expect(filled?.anonymous == false)
        #expect(filled.map { fixture.passwords.password(for: PasswordVault.account(of: $0)) } == "anna-pw")
        // Not for a guest login, nor for another user.
        #expect(fixture.passwords.password(for: PasswordVault.account(of: guest)) == nil)
        #expect(fixture.passwords.password(for: PasswordVault.account(of: bob)) == nil)
        #expect(!fixture.passwords.accounts.contains { $0.contains("nobody") })
    }

    /// The question whether to connect says how the login would be made.
    @Test
    internal func theQuestionWhetherToConnectSaysHowTheLoginIsMade() {
        let secure = ServerKey(scheme: "sftp", host: "files.example.com")
        scripted.choiceAnswers = [0]
        #expect(fixture.environment.askToConnect(ConnectionProfile(key: secure)))
        #expect(scripted.log.last?.contains("A secure shell login as \(NSUserName()) would be made") == true)
        #expect(!fixture.environment.askToConnect(ConnectionProfile(key: fixture.key, user: "anna")))
        #expect(scripted.log.last?.contains("A login as anna would be made.") == true)
    }

    /// Hosts allowed to get a password unencrypted are remembered one after the other.
    @Test
    internal func hostsAllowedAnUnencryptedPasswordAreRemembered() {
        let ask = fixture.environment.askToSendPasswordUnprotected
        for host in ["one.example.com", "two.example.com"] {
            scripted.formAnswers = [.values(["always": .flag(true)])]
            #expect(ask(ConnectionProfile(key: ServerKey(scheme: "ftp", host: host))))
        }
        let stored = fixture.settings.value([String].self, forKey: "network.unprotectedPasswordHosts")
        #expect(stored == ["one.example.com", "two.example.com"])
        // Asked no more for them.
        let forms = scripted.forms.count
        #expect(ask(ConnectionProfile(key: ServerKey(scheme: "ftp", host: "one.example.com"))))
        #expect(scripted.forms.count == forms)
    }

    /// A certificate question that is cancelled trusts nothing.
    @Test
    internal func aCancelledCertificateQuestionTrustsNothing() {
        let certificate = CertificateInfo(fingerprint: "AA:BB", subject: "files", problem: "self-signed")
        let profile = ConnectionProfile(key: ServerKey(scheme: "ftps", host: "files.example.com"))
        scripted.formAnswers = [.cancel]
        #expect(!fixture.environment.askToTrust(profile, certificate))
        #expect(!fixture.environment.trust.isAccepted("AA:BB", for: "files.example.com"))
    }

    /// The secure shell's questions: a host key is confirmed only by Yes, a secret is typed.
    @Test
    internal func theSecureShellsQuestionsAreAnswered() {
        let profile = ConnectionProfile(key: ServerKey(scheme: "sftp", host: "files.example.com"))
        let ask = fixture.environment.askSecret
        scripted.choiceAnswers = [0]
        #expect(ask(profile, "Are you sure you want to continue connecting?", false) == "yes")
        #expect(ask(profile, "Are you sure you want to continue connecting?", false) == "no")
        scripted.formAnswers = [.values(["secret": .text("key phrase")])]
        #expect(ask(profile, "Enter passphrase for key:", true) == "key phrase")
        #expect(ask(profile, "Enter passphrase for key:", true) == nil)
    }
}
