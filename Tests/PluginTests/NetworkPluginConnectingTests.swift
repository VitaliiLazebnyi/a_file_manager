import AFMContracts
import AFMKernel
import Foundation
import NetworkPlugin
import TestSupport
import Testing

/// The network plugin's connection dialogs: connecting, disconnecting, saved connections and the questions asked
/// on the way.
@MainActor
@Suite
internal struct NetworkPluginConnectingTests: NetworkCommandSuite {
    /// The bench, the server and the plugin of the test.
    internal let fixture: NetworkCommandFixture

    /// A fresh fixture for every test.
    internal init() throws {
        fixture = try NetworkCommandFixture()
    }

    /// A quick connection shows the server in the panel, where folders open as usual, and Disconnect
    /// returns to the local folder after offering to save it.
    @Test
    internal func quickConnectShowsTheServerAndDisconnectReturns() {
        quickConnect()
        #expect(left.model.directory == url("/") && left.names == ["pub", "readme.txt"])
        #expect(left.model.volume?.isLocal == false)
        #expect(bench.jobService.titles == ["Connect to ftp://\(address)"])
        #expect(commands.isEnabled(.ftpDisconnect) && commands.isEnabled(.ftpHiddenFiles))
        #expect(bench.kernel.fileSystems.all.flatMap { $0.places() }.contains { $0.url == url("/") })
        // Entering a folder and going up again is ordinary navigation.
        left.moveCursor(toName: "pub")
        commands.perform(.open)
        #expect(left.model.directory == url("/pub") && left.names == ["sub", "report.txt"])
        commands.perform(.goToParent)
        #expect(left.model.directory == url("/") && left.model.cursorItem?.name == "pub")

        // A quick connection offers to be saved; No just disconnects.
        dialogs.choiceAnswers = [1]
        commands.perform(.ftpDisconnect)
        #expect(dialogs.log.contains { $0.hasPrefix("choose: Current session not saved, save?") })
        #expect(left.model.directory == box.url("local") && !plugin.center.isConnected(key))
        #expect(!commands.isEnabled(.ftpDisconnect) && plugin.connections.isEmpty)
    }

    /// Saving a quick connection on disconnect keeps its server and folder, and it opens again by name.
    @Test
    internal func disconnectCanSaveTheQuickConnection() throws {
        quickConnect("ftp://\(address)/pub")
        #expect(left.model.directory == url("/pub"))
        // Yes opens the connection details, filled in from the session.
        dialogs.choiceAnswers = [0]
        dialogs.formAnswers = [.values(["name": .text("Test box")])]
        commands.perform(.ftpDisconnect)
        let saved = try #require(plugin.connections.first)
        #expect(saved.name == "Test box" && saved.host == "127.0.0.1" && saved.port == server.port && saved.anonymous)
        #expect(saved.remoteDirectory == "/pub" && saved.kind == .ftp)
        #expect(left.model.directory == box.url("local"))
        // The saved connection opens by its name, whatever the case.
        commands.perform(.ftpOpen, .text("test box"))
        #expect(left.model.directory == url("/pub"))
        commands.perform(.ftpDisconnect)
        #expect(left.model.directory == box.url("local"), "a saved connection disconnects without asking")
    }

    /// A server that does not answer and an address that is none are reported, and the panel stays.
    @Test
    internal func aFailedConnectionIsReportedAndLeavesThePanel() {
        server.stop()
        quickConnect()
        #expect(left.model.directory == box.url("local"))
        #expect(dialogs.log.contains("inform: Connect failed!") && !plugin.center.isConnected(key))
        quickConnect("not a server address")
        #expect(dialogs.log.last == "inform: not a server address is not a server address.")
    }

    /// A saved connection's password goes to the password store under an account naming the connection, never
    /// into the settings, and the connection logs in with it.
    @Test
    internal func savedConnectionsKeepTheirPasswordInThePasswordStore() throws {
        saveAndConnectWork()
        let saved = try #require(plugin.connections.first)
        #expect(saved.name == "Work" && saved.user == "anna" && saved.remoteDirectory == "/pub")
        // Under a name that says whose password it is: this connection's, on this server, for this user.
        plugin.waitForStoredSecrets()
        let account = PasswordVault.account(of: saved)
        #expect(account.contains(saved.id.uuidString) && account.contains("anna@127.0.0.1:\(server.port)"))
        #expect(
            passwords.password(for: account) == "s3cret-pw"
                && passwords.accounts == [PasswordVault.boundAccount, account].sorted()
        )
        #expect(
            !settings.everything.contains(Data("s3cret-pw".utf8)),
            "the password never reaches the settings"
        )
        #expect(dialogs.forms[1].contains { $0.label.contains("master password is not needed") })
        // Connected with the stored password, in the remote folder, the other panel in the local one.
        #expect(left.model.directory == url("/pub") && right.model.directory == box.url("other"))
        #expect(server.commands.contains("USER anna") && server.commands.contains("PASS s3cret-pw"))
        #expect(left.model.volume?.name == "Work")
        #expect(!dialogs.log.contains { $0.hasPrefix("choose:") })
    }

    /// Duplicate, Edit and Delete in the list of saved connections; deleting a connection and unticking the box
    /// both remove its password from the store.
    @Test
    internal func deletingAConnectionOrUntickingTheBoxRemovesThePassword() {
        saveAndConnectWork()
        plugin.waitForStoredSecrets()
        commands.perform(.ftpDisconnect)
        dialogs.formAnswers = [
            .values([:], button: 3), .values(["name": .text("Work copy")]),
            .values(["connection": .index(1)], button: 4),
            .values(["name": .text("Second"), "savePassword": .flag(false)]),
            .values(["connection": .index(0)], button: 5)
        ]
        dialogs.choiceAnswers = [0]
        commands.perform(.ftpConnect)
        #expect(plugin.connections.map(\.name) == ["Second"])
        plugin.waitForStoredSecrets()
        #expect(
            passwords.accounts == [PasswordVault.boundAccount],
            "deleting a connection and unticking the box both remove the password"
        )
        #expect(
            dialogs.forms.last?.first
                .map { field -> Bool in
                    if case .list(let rows, _) = field.kind {
                        return rows.count == 1 && rows[0].hasPrefix("Second")
                    }
                    return false
                } == true
        )
    }

    /// Ctrl+F with a server that wants a password: New Connection…, the details of "Work" with its password, then
    /// Connect on the new entry.
    private func saveAndConnectWork() {
        server.options.user = "anna"
        server.options.password = "s3cret-pw"
        dialogs.formAnswers = [
            .values([:], button: 1),
            .values([
                "name": .text("Work"), "host": .text(address), "user": .text("anna"), "password": .text("s3cret-pw"),
                "remote": .text("/pub"), "local": .text(box.url("other").path)
            ]),
            .accept
        ]
        commands.perform(.ftpConnect)
    }

    /// Without a stored password the user name and password are asked while connecting, and the
    /// remembered address never holds the password.
    @Test
    internal func asksForAPasswordThatIsNotStored() {
        server.options.user = "anna"
        server.options.password = "pw"
        // Not anonymous and no user in the address: user name and password are asked while connecting.
        dialogs.formAnswers = [
            .values(["address": .text(address), "anonymous": .flag(false)]),
            .values(["user": .text("anna"), "password": .text("pw")])
        ]
        commands.perform(.ftpNew)
        #expect(left.model.directory == url("/") && dialogs.log.contains("form: ftp://\(address)"))
        dialogs.choiceAnswers = [1]
        commands.perform(.ftpDisconnect)
        // Cancelling the question ends the attempt without an error box.
        dialogs.formAnswers = [.values(["address": .text("anna@" + address)]), .cancel]
        commands.perform(.ftpNew)
        #expect(left.model.directory == box.url("local") && !dialogs.log.contains("inform: Connect failed!"))
        // The remembered address has the user name and never a password.
        dialogs.formAnswers = [.values(["address": .text("ftp://anna:pw@\(address)/pub")])]
        commands.perform(.ftpNew)
        #expect(left.model.directory == url("/pub"))
        #expect(!settings.everything.contains(Data("anna:pw".utf8)))
        #expect(settings.value([String].self, forKey: "network.history")?.first == "ftp://anna@\(address)/pub")
    }

    /// A server URL typed for `cd` connects by itself, after asking once.
    @Test
    internal func aTypedURLConnectsByItself() {
        // `cd ftp://…` (spec 11 › Opening connections by command).
        // Nobody chose this server in a dialog of the program, so the user is asked first. (Answered
        // here without the dialog: the test's panel reads on the main thread, where the dialog
        // would be shown. The dialog itself is tested below.)
        nonisolated(unsafe) var asked: [ServerKey] = []
        plugin.center.environment.askToConnect = { profile in
            asked.append(profile.key)
            return true
        }
        commands.perform(.changeDirectory, .text("ftp://\(address)/pub/sub"))
        // Asked once, unless whoever read the line said that the user typed it (`ServerConsentService`,
        // see the next test): then there is no question.
        #expect(asked == [key] || asked.isEmpty)
        #expect(left.model.directory == url("/pub/sub") && left.names == ["deep.txt"])
        #expect(plugin.center.isConnected(key))
    }

    /// An address the user typed in person is not asked about, and the plugin's settings keys are declared.
    @Test
    internal func anAddressTheUserTypedInPersonIsNotAskedAbout() throws {
        // Used by the callbacks, which run one at a time while the calls below wait for them.
        nonisolated(unsafe) var asked: [ServerKey] = []
        plugin.center.environment.askToConnect = { profile in
            asked.append(profile.key)
            return true
        }
        // The plugin offers the service whoever takes a location from the keyboard calls.
        let consent = try #require(bench.kernel.services.find((any ServerConsentService).self))
        consent.userChose(url("/pub/sub"))
        commands.perform(.changeDirectory, .text("ftp://\(address)/pub/sub"))
        #expect(asked.isEmpty)
        #expect(left.model.directory == url("/pub/sub") && left.names == ["deep.txt"])
        #expect(plugin.center.isConnected(key))
        // The keys of the settings are declared for whoever exports or imports them.
        #expect(bench.kernel.settingsKeys.kind(of: "network.connections") == .connection)
        #expect(bench.kernel.settingsKeys.kind(of: "network.unprotectedPasswordHosts") == .trust)
        #expect(bench.kernel.settingsKeys.kind(of: "network.history") == .history)
    }

    /// The question before connecting, and the one before sending a password unencrypted, which is not
    /// asked again for a server the user said so for.
    @Test
    internal func theQuestionsBeforeConnecting() {
        let environment = plugin.center.environment
        var profile = ConnectionProfile(key: key, anonymous: true)
        profile.asksBeforeConnecting = true
        dialogs.choiceAnswers = [1, 0]
        #expect(!environment.askToConnect(profile) && environment.askToConnect(profile))
        #expect(
            dialogs.log
                .filter { line in
                    line.hasPrefix("choose: Connect to ftp://\(address)? / ")
                        && line.contains("did not choose to connect")
                }
                .count == 2
        )
        // A password over plain FTP: asked, and not again for a server the user said so for.
        let secret = ConnectionProfile(
            key: ServerKey(scheme: "ftp", host: "files.example.com"),
            user: "anna",
            password: "pw"
        )
        dialogs.formAnswers = [.cancel, .values(["always": .flag(true)])]
        #expect(!environment.askToSendPasswordUnprotected(secret) && environment.askToSendPasswordUnprotected(secret))
        #expect(environment.askToSendPasswordUnprotected(secret), "no third question")
        #expect(dialogs.log.filter { $0 == "form: Send the password unencrypted?" }.count == 2)
    }
}
