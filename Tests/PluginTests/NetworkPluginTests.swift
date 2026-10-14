import AFMContracts
import AFMKernel
import FileOperationsPlugin
import Foundation
import LocalFileSystemPlugin
import NavigationPlugin
import NetworkPlugin
import TestSupport
import Testing
import ViewOptionsPlugin

/// Settings that remember every value ever stored, to prove what never went through them.
private final class RecordingSettings: SettingsStore {
    private var values: [String: Data] = [:]
    private(set) var everything = Data()

    func data(forKey key: String) -> Data? { values[key] }

    func set(_ data: Data?, forKey key: String) {
        values[key] = data
        everything.append(Data(key.utf8))
        if let data { everything.append(data) }
    }
}

/// Stands in for the system when volumes are mounted and ejected.
private final class FakeMounter: VolumeMounter {
    var mounted: [URL] = []
    var ejected: [URL] = []
    var mountPoint = URL(fileURLWithPath: "/")
    var failure: Error?

    func mount(_ url: URL) throws -> [URL] {
        if let failure { throw failure }
        mounted.append(url)
        return [mountPoint]
    }

    func unmount(_ volume: URL) throws { ejected.append(volume) }
}

/// The network plugin driven through its commands: the connection dialogs, the panels on a
/// server, and the real copy job between the test server and the local disk.
@MainActor @Suite struct NetworkPluginCommands {
    let box: Sandbox
    let server: TestFTPServer
    let passwords = MemoryPasswords()
    private let settings = RecordingSettings()
    private let mounter = FakeMounter()
    let plugin: NetworkPlugin
    let bench: TestBench

    var commands: CommandRegistry { bench.commands }
    var left: FakePanel { bench.left }
    var right: FakePanel { bench.right }
    var ui: ScriptedInteraction { bench.ui }
    var key: ServerKey { ServerKey(scheme: "ftp", host: "127.0.0.1", port: server.port) }
    var address: String { "127.0.0.1:\(server.port)" }

    init() throws {
        box = try Sandbox()
        try box.file("srv/pub/report.txt", "report")
        try box.file("srv/pub/sub/deep.txt", "deep")
        try box.file("srv/readme.txt", "read me")
        try box.file("local/up.txt", "upload")
        try box.file("local/tree/a.txt", "a")
        try box.file("local/tree/inner/b.txt", "bb")
        try box.folder("other")
        server = try TestFTPServer(root: box.url("srv"))
        settings.set("0", forKey: "network.keepAliveSeconds")
        plugin = NetworkPlugin(launchesApplications: false, passwords: passwords, mounter: mounter)
        bench = TestBench(
            plugins: [plugin, NavigationPlugin(), FileOperationsPlugin(), ViewOptionsPlugin()],
            fileSystems: [LocalFileSystem()],
            left: box.url("local"), right: box.url("other"), settings: settings)
        plugin.center.environment.declineMemory = 0
    }

    func url(_ path: String) -> URL { key.url(path: path) }
    /// The folder of the right panel as a copy target.
    var localTarget: String { box.url("other").absoluteString + "/" }

    /// Ctrl+N with the test server's address.
    func quickConnect(_ text: String? = nil, anonymous: Bool = true) {
        ui.formAnswers = [.values(["address": .text(text ?? address), "anonymous": .flag(anonymous)])]
        commands.perform(.ftpNew)
    }

    // MARK: Registration

    @Test func registersCommandsMenusAndFileSystems() throws {
        let net = try #require(bench.kernel.menus.menus.first { $0.title == "Net" })
        #expect(
            net.items == [
                .ftpConnect, .ftpNew, .ftpDisconnect, .ftpHiddenFiles, nil,
                .ftpSelectTransferMode, .ftpAddToList, .ftpDownloadList, nil, .netConnect, .netDisconnect
            ])
        #expect(net.items.compactMap { $0 }.allSatisfy { commands[$0] != nil })
        #expect(bench.kernel.keyBindings.conflicts.isEmpty)
        #expect(commands[.ftpConnect]?.defaultShortcuts == [Shortcut(.character("f"), .control)])
        #expect(commands[.ftpNew]?.defaultShortcuts == [Shortcut(.character("n"), .control)])
        #expect(commands[.ftpDisconnect]?.defaultShortcuts == [Shortcut(.character("f"), [.control, .shift])])
        #expect(bench.kernel.fileSystems.all.map(\.scheme).filter { $0 != "file" } == ["ftp", "ftps", "sftp"])
        let ours: [CommandID] = [.ftpConnect, .ftpNew, .ftpDisconnect, .netConnect]
        #expect(bench.kernel.toolbar.defaultLayout.compactMap { $0?.command }.filter(ours.contains) == ours)
        #expect(bench.kernel.preferences.pages.map(\.title).contains("FTP and Network"))
        // Nothing is connected: nothing to disconnect, no server among the volumes, no eject on the startup disk.
        #expect(
            !commands.isEnabled(.ftpDisconnect) && !commands.isEnabled(.ftpHiddenFiles)
                && !commands.isEnabled(.netDisconnect))
        #expect(bench.kernel.fileSystems.all.flatMap { $0.places() }.filter { !$0.url.isFileURL }.isEmpty)
    }

    // MARK: Connecting and disconnecting

    @Test func quickConnectShowsTheServerAndDisconnectReturns() throws {
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
        ui.choiceAnswers = [1]
        commands.perform(.ftpDisconnect)
        #expect(ui.log.contains { $0.hasPrefix("choose: Current session not saved, save?") })
        #expect(left.model.directory == box.url("local") && !plugin.center.isConnected(key))
        #expect(!commands.isEnabled(.ftpDisconnect) && plugin.connections.isEmpty)
    }

    @Test func disconnectCanSaveTheQuickConnection() throws {
        quickConnect("ftp://\(address)/pub")
        #expect(left.model.directory == url("/pub"))
        // Yes opens the connection details, filled in from the session.
        ui.choiceAnswers = [0]
        ui.formAnswers = [.values(["name": .text("Test box")])]
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

    @Test func aFailedConnectionIsReportedAndLeavesThePanel() {
        server.stop()
        quickConnect()
        #expect(left.model.directory == box.url("local"))
        #expect(ui.log.contains("inform: Connect failed!") && !plugin.center.isConnected(key))
        quickConnect("not a server address")
        #expect(ui.log.last == "inform: not a server address is not a server address.")
    }

    @Test func savedConnectionsKeepTheirPasswordInThePasswordStore() throws {
        server.options.user = "anna"
        server.options.password = "s3cret-pw"
        // Ctrl+F: New Connection…, fill in the details, then Connect on the new entry.
        ui.formAnswers = [
            .values([:], button: 1),
            .values([
                "name": .text("Work"), "host": .text(address), "user": .text("anna"), "password": .text("s3cret-pw"),
                "remote": .text("/pub"), "local": .text(box.url("other").path)
            ]),
            .accept
        ]
        commands.perform(.ftpConnect)
        let saved = try #require(plugin.connections.first)
        #expect(saved.name == "Work" && saved.user == "anna" && saved.remoteDirectory == "/pub")
        // Under a name that says whose password it is: this connection's, on this server, for this user.
        plugin.waitForStoredSecrets()
        let account = PasswordVault.account(of: saved)
        #expect(account.contains(saved.id.uuidString) && account.contains("anna@127.0.0.1:\(server.port)"))
        #expect(
            passwords.password(for: account) == "s3cret-pw"
                && passwords.accounts == [PasswordVault.boundAccount, account].sorted())
        #expect(
            settings.everything.range(of: Data("s3cret-pw".utf8)) == nil, "the password never reaches the settings")
        #expect(ui.forms[1].contains { $0.label.contains("master password is not needed") })
        // Connected with the stored password, in the remote folder, the other panel in the local one.
        #expect(left.model.directory == url("/pub") && right.model.directory == box.url("other"))
        #expect(server.commands.contains("USER anna") && server.commands.contains("PASS s3cret-pw"))
        #expect(left.model.volume?.name == "Work")
        #expect(!ui.log.contains { $0.hasPrefix("choose:") })
        commands.perform(.ftpDisconnect)

        // Duplicate, Edit and Delete in the list.
        ui.formAnswers = [
            .values([:], button: 3), .values(["name": .text("Work copy")]),
            .values(["connection": .index(1)], button: 4),
            .values(["name": .text("Second"), "savePassword": .flag(false)]),
            .values(["connection": .index(0)], button: 5)
        ]
        ui.choiceAnswers = [0]
        commands.perform(.ftpConnect)
        #expect(plugin.connections.map(\.name) == ["Second"])
        plugin.waitForStoredSecrets()
        #expect(
            passwords.accounts == [PasswordVault.boundAccount],
            "deleting a connection and unticking the box both remove the password")
        #expect(
            ui.forms.last?.first.map { field -> Bool in
                if case .list(let rows, _) = field.kind { return rows.count == 1 && rows[0].hasPrefix("Second") }
                return false
            } == true)
    }

    @Test func asksForAPasswordThatIsNotStored() throws {
        server.options.user = "anna"
        server.options.password = "pw"
        // Not anonymous and no user in the address: user name and password are asked while connecting.
        ui.formAnswers = [
            .values(["address": .text(address), "anonymous": .flag(false)]),
            .values(["user": .text("anna"), "password": .text("pw")])
        ]
        commands.perform(.ftpNew)
        #expect(left.model.directory == url("/") && ui.log.contains("form: ftp://\(address)"))
        ui.choiceAnswers = [1]
        commands.perform(.ftpDisconnect)
        // Cancelling the question ends the attempt without an error box.
        ui.formAnswers = [.values(["address": .text("anna@" + address)]), .cancel]
        commands.perform(.ftpNew)
        #expect(left.model.directory == box.url("local") && !ui.log.contains("inform: Connect failed!"))
        // The remembered address has the user name and never a password.
        ui.formAnswers = [.values(["address": .text("ftp://anna:pw@\(address)/pub")])]
        commands.perform(.ftpNew)
        #expect(left.model.directory == url("/pub"))
        #expect(settings.everything.range(of: Data("anna:pw".utf8)) == nil)
        #expect(settings.value([String].self, forKey: "network.history")?.first == "ftp://anna@\(address)/pub")
    }

    @Test func aTypedURLConnectsByItself() {
        // `cd ftp://…` (spec 11 › Opening connections by command).
        // Nobody chose this server in a dialog of the program, so the user is asked first. (Answered
        // here without the dialog: the test's panel reads on the main thread, where the dialog
        // would be shown. The dialog itself is tested below.)
        var asked: [ServerKey] = []
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

    @Test func anAddressTheUserTypedInPersonIsNotAskedAbout() throws {
        var asked: [ServerKey] = []
        plugin.center.environment.askToConnect = { profile in
            asked.append(profile.key)
            return true
        }
        // The plugin offers the service whoever takes a location from the keyboard calls.
        let consent = try #require(bench.kernel.services.find(ServerConsentService.self))
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

    @Test func theQuestionsBeforeConnecting() {
        let environment = plugin.center.environment
        var profile = ConnectionProfile(key: key, anonymous: true)
        profile.asksBeforeConnecting = true
        ui.choiceAnswers = [1, 0]
        #expect(!environment.askToConnect(profile) && environment.askToConnect(profile))
        #expect(
            ui.log.filter {
                $0.hasPrefix("choose: Connect to ftp://\(address)? / ") && $0.contains("did not choose to connect")
            }.count == 2)
        // A password over plain FTP: asked, and not again for a server the user said so for.
        let secret = ConnectionProfile(
            key: ServerKey(scheme: "ftp", host: "files.example.com"), user: "anna", password: "pw")
        ui.formAnswers = [.cancel, .values(["always": .flag(true)])]
        #expect(!environment.askToSendPasswordUnprotected(secret) && environment.askToSendPasswordUnprotected(secret))
        #expect(environment.askToSendPasswordUnprotected(secret), "no third question")
        #expect(ui.log.filter { $0 == "form: Send the password unencrypted?" }.count == 2)
    }

    // MARK: File operations on the server

    @Test func downloadsWithTheCopyJob() throws {
        quickConnect("ftp://\(address)/pub")
        right.show(box.url("other"))
        // One file, then a folder with what is in it. The target is written as a `file:` URL:
        // a plain path typed for a server panel means a path on that server.
        left.moveCursor(toName: "report.txt")
        ui.promptAnswers = [.text(localTarget)]
        commands.perform(.copy)
        #expect(box.read("other/report.txt") == "report")
        left.moveCursor(toName: "sub")
        ui.promptAnswers = [.text(localTarget)]
        commands.perform(.copy)
        #expect(box.read("other/sub/deep.txt") == "deep")
        #expect(!ui.log.contains { $0.hasPrefix("choose: Error") })
        #expect(namesOnDisk(box.url("other")) == ["report.txt", "sub"], "no temporary file is left")
    }

    @Test func uploadsRenamesAndDeletesWithTheUsualCommands() throws {
        quickConnect("ftp://\(address)/pub")
        bench.panelSet.source = right
        right.show(box.url("local"))
        // The proposed target is the server folder as the user reads it.
        right.model.selectAll()
        ui.promptAnswers = [.accept]
        commands.perform(.copy)
        #expect(ui.log.contains("prompt: Copy 2 file(s) to [ftp://\(address)/pub/*.*]"))
        #expect(box.read("srv/pub/up.txt") == "upload" && box.read("srv/pub/tree/inner/b.txt") == "bb")
        #expect(namesOnDisk(box.url("srv/pub")) == ["report.txt", "sub", "tree", "up.txt"])
        #expect(left.names == ["sub", "tree", "report.txt", "up.txt"], "the server panel was re-read")

        // Uploading again asks before it overwrites.
        try box.file("local/up.txt", "second version")
        right.model.clearSelection()
        right.moveCursor(toName: "up.txt")
        ui.promptAnswers = [.accept]
        ui.choiceAnswers = [0]
        commands.perform(.copy)
        #expect(
            ui.log.contains { $0.hasPrefix("choose: Overwrite:") } && box.read("srv/pub/up.txt") == "second version")

        bench.panelSet.source = left
        // Rename in place, new folder, delete a tree.
        left.moveCursor(toName: "up.txt")
        commands.perform(.renameOnly, .text("renamed.txt"))
        #expect(
            box.exists("srv/pub/renamed.txt") && !box.exists("srv/pub/up.txt")
                && left.model.cursorItem?.name == "renamed.txt")
        ui.promptAnswers = [.text("new/nested")]
        commands.perform(.makeDirectory)
        #expect(box.exists("srv/pub/new/nested"))
        left.moveCursor(toName: "tree")
        // F8 on a server deletes directly: there is no Trash. Yes, then "delete the non-empty folder".
        ui.choiceAnswers = [0, 0]
        commands.perform(.delete)
        #expect(!box.exists("srv/pub/tree") && left.names == ["new", "sub", "renamed.txt", "report.txt"])
        #expect(!ui.log.contains { $0.hasPrefix("choose: Error") })
    }

    @Test func movesBetweenServerAndDisk() throws {
        quickConnect("ftp://\(address)/pub")
        left.moveCursor(toName: "report.txt")
        ui.promptAnswers = [.text(localTarget)]
        commands.perform(.renameMove)
        #expect(box.read("other/report.txt") == "report" && !box.exists("srv/pub/report.txt"))
        // Within the server a move is a rename.
        left.moveCursor(toName: "sub")
        ui.promptAnswers = [.text("ftp://\(address)/moved")]
        commands.perform(.renameMove)
        #expect(box.read("srv/moved/deep.txt") == "deep" && !box.exists("srv/pub/sub"))
        #expect(server.commands.contains("RNFR /pub/sub") && server.commands.contains("RNTO /moved"))
    }

    // MARK: Options

    @Test func hiddenFilesAndTransferMode() throws {
        try box.file("srv/.secret", "s")
        quickConnect()
        #expect(left.names == ["pub", "readme.txt"] && !commands.isChecked(.ftpHiddenFiles))
        commands.perform(.ftpHiddenFiles)
        #expect(left.names == ["pub", ".secret", "readme.txt"] && commands.isChecked(.ftpHiddenFiles))

        #expect(plugin.center.environment.options.values.transferMode == .binary)
        ui.formAnswers = [.values(["mode": .index(1)])]
        commands.perform(.ftpSelectTransferMode)
        #expect(plugin.center.environment.options.values.transferMode == .text)
        // The preference page reads the same settings.
        let page = try #require(bench.kernel.preferences.pages.first)
        settings.set(false, forKey: "network.passiveMode")
        settings.set(5, forKey: "network.parallelConnections")
        settings.set("15", forKey: "network.timeoutSeconds")
        page.onChange()
        let values = plugin.center.environment.options.values
        #expect(
            !values.passiveByDefault && values.parallelConnections == 8 && values.timeout == 15
                && values.transferMode == .text)
    }

    // MARK: Download list

    @Test func downloadListIsWrittenAndWorkedThrough() throws {
        quickConnect("ftp://\(address)/pub")
        let list = box.url("list.txt")
        left.moveCursor(toName: "report.txt")
        ui.promptAnswers = [.text(list.path)]
        commands.perform(.ftpAddToList)
        #expect(box.read("list.txt") == "ftp://\(address)/pub/report.txt -> \(box.url("other/report.txt").path)\n")
        #expect(!box.exists("other/report.txt"), "download later downloads nothing")

        // More lines: a target with another name, one without a target, an upload, and one that cannot be done.
        try
            (box.read("list.txt")! + "ftp://\(address)/readme.txt -> \(box.url("other/README.md").path)\n"
            + "ftp://\(address)/pub/sub/deep.txt\nput:\(box.url("local/up.txt").path) -> ftp://\(address)/pub/sub/up.txt\nheader: X: y\n")
            .write(to: list, atomically: true, encoding: .utf8)
        ui.promptAnswers = [.accept]
        // What the list would do is shown, and it runs when the user agrees.
        ui.choiceAnswers = [0]
        commands.perform(.ftpDownloadList)
        #expect(ui.log.contains("prompt: File name of download list: [\(list.path)]"), "the last list is proposed")
        #expect(ui.log.contains { $0.hasPrefix("choose: Run this download list? (3 downloads, 1 uploads or copies)") })
        #expect(box.read("other/report.txt") == "report" && box.read("other/README.md") == "read me")
        #expect(box.read("other/deep.txt") == "deep" && box.read("srv/pub/sub/up.txt") == "upload")
        #expect(ui.log.last == "inform: Some lines of the download list were not carried out.")
    }

    // MARK: Network volumes

    @Test func connectToServerMountsAndEjects() throws {
        let volume = try box.folder("Volumes/Share")
        mounter.mountPoint = volume
        ui.promptAnswers = [.text("smb://nas.local/Share")]
        commands.perform(.netConnect)
        #expect(mounter.mounted.map(\.absoluteString) == ["smb://nas.local/Share"])
        #expect(left.model.directory == volume && ui.log.contains("prompt: Connect to Server [smb://]"))
        // An address of this program's own kind opens a connection instead.
        commands.perform(.netConnect, .text("ftp://\(address)/pub"))
        #expect(left.model.directory == url("/pub") && mounter.mounted.count == 1)
        commands.perform(.netConnect, .text("gopher://old"))
        #expect(ui.log.last == "inform: gopher://old is not the address of a server.")
        mounter.failure = VolumeError(message: "No route")
        commands.perform(.netConnect, .text("afp://nas.local/x"))
        #expect(ui.log.last == "inform: Connect failed!")
        // Eject is offered for folders on a mounted volume only; the sandbox is not one.
        #expect(!commands.isEnabled(.netDisconnect) && mounter.ejected.isEmpty)
    }
}
