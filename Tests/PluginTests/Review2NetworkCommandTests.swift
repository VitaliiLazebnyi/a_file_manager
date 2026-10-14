import AFMContracts
import AFMKernel
import FileOperationsPlugin
import Foundation
import LocalFileSystemPlugin
import NavigationPlugin
@testable import NetworkPlugin
import TestSupport
import Testing
import ViewOptionsPlugin

/// Stands in for the system when volumes are mounted.
private final class RefusingMounter: VolumeMounter {
    var cancelled = false
    func mount(_ url: URL) throws -> [URL] {
        throw VolumeError(message: "The server \(ServerAddress.removingPassword(from: url.absoluteString)) could not be connected: no route.")
    }
    func unmount(_ volume: URL) throws {}
}

/// The Net commands (review 2: N003, N016, N017, N018, N020, N033, N083, N084, N086, N100, N104, N105).
@MainActor @Suite struct Review2NetworkCommands {
    let box: Sandbox
    let server: TestFTPServer
    let passwords = MemoryPasswords()
    let settings = MemorySettings()
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
        try box.file("srv/readme.txt", "read me")
        try box.file("local/up.txt", "upload")
        try box.folder("other")
        server = try TestFTPServer(root: box.url("srv"))
        settings.set("0", forKey: "network.keepAliveSeconds")
        plugin = NetworkPlugin(launchesApplications: false, passwords: passwords, mounter: RefusingMounter())
        bench = TestBench(plugins: [plugin, NavigationPlugin(), FileOperationsPlugin(), ViewOptionsPlugin()], fileSystems: [LocalFileSystem()],
                          left: box.url("local"), right: box.url("other"), settings: settings)
        plugin.center.environment.declineMemory = 0
    }

    func url(_ path: String) -> URL { key.url(path: path) }

    func quickConnect(_ text: String) {
        ui.formAnswers = [.values(["address": .text(text), "anonymous": .flag(true)])]
        commands.perform(.ftpNew)
    }

    private func runList(_ lines: [String], answers: [Int]) throws {
        let list = try box.file("list.txt", lines.joined(separator: "\n") + "\n")
        ui.promptAnswers = [.text(list.path)]
        ui.choiceAnswers = answers
        commands.perform(.ftpDownloadList)
    }

    // MARK: Download list

    @Test func aListIsShownBeforeItRunsAndNothingHappensWithoutAYes() throws {
        quickConnect("ftp://\(address)/pub")
        // The last button, Cancel.
        try runList(["ftp://\(address)/pub/report.txt -> \(box.url("other/got.txt").path)",
                     "put:\(box.url("local/up.txt").path) -> ftp://\(address)/pub/sent.txt",
                     "move:\(box.url("local/up.txt").path) -> ftp://\(address)/pub/moved.txt"], answers: [1])
        let question = try #require(ui.log.last { $0.hasPrefix("choose: Run this download list?") })
        // What each line would do, and that this list does more than download.
        #expect(question.contains("1 downloads, 1 uploads or copies, 1 moves"))
        #expect(question.contains("Download: ftp://\(address)/pub/report.txt"))
        #expect(question.contains("Upload: ") && question.contains("Move (the source is deleted)"))
        #expect(question.contains("does more than download"))
        #expect(!box.exists("other/got.txt") && !box.exists("srv/pub/sent.txt") && box.exists("local/up.txt"))
        #expect(!server.commands.contains { $0.hasPrefix("STOR") || $0.hasPrefix("RETR") })
    }

    @Test func anExistingFileIsNotReplacedWithoutAsking() throws {
        quickConnect("ftp://\(address)/pub")
        // The list wants the download to take the name of a file that is already there.
        let precious = try box.file("other/precious.txt", "mine")
        try runList(["ftp://\(address)/pub/report.txt -> \(precious.path)"], answers: [0, 1])
        #expect(ui.log.contains { $0.hasPrefix("choose: \(precious.path) already exists.") })
        // Not replaced: the file that arrived keeps its own name.
        #expect(box.read("other/precious.txt") == "mine" && box.read("other/report.txt") == "report")
        // Replaced when the user says so.
        try FileManager.default.removeItem(at: box.url("other/report.txt"))
        try runList(["ftp://\(address)/pub/report.txt -> \(precious.path)"], answers: [0, 0])
        #expect(box.read("other/precious.txt") == "report" && !box.exists("other/report.txt"))
    }

    @Test func aPlainLineOnlyDownloads() throws {
        quickConnect("ftp://\(address)/pub")
        // No `put:`: a plain line that would send a file of this Mac away, or copy between
        // two local places, is not carried out.
        try runList(["\(box.url("local/up.txt").path) -> ftp://\(address)/pub/stolen.txt",
                     "\(box.url("local/up.txt").path) -> \(box.url("other/copy.txt").path)",
                     "ftp://\(address)/readme.txt -> ftp://\(address)/pub/readme-copy.txt",
                     "ftp://\(address)/readme.txt"], answers: [0])
        #expect(box.read("other/readme.txt") == "read me")
        #expect(!box.exists("srv/pub/stolen.txt") && !box.exists("other/copy.txt") && !box.exists("srv/pub/readme-copy.txt"))
        #expect(ui.log.last == "inform: Some lines of the download list were not carried out.")
    }

    @Test func aListOfLinesThatCannotBeCarriedOutIsToldInShort() throws {
        // Very many lines that are no transfers: one message, and no call inside a call for each.
        let lines = (0..<30_000).map { "header: X-\($0): y" }
        try runList(lines, answers: [])
        #expect(ui.log.last?.hasPrefix("inform: The download list") == true)
        #expect(ListPlan.shortened(lines).split(separator: "\n").count == ListPlan.shownLines + 1)
        #expect(ListPlan.shortened(lines).hasSuffix("… and \(30_000 - ListPlan.shownLines) more"))
        // Very many lines that are carried out, each ending at once (the source is not there).
        let missing = (0..<3000).map { "ftp://\(address)/none\($0).txt" }
        quickConnect("ftp://\(address)/pub")
        try runList(missing, answers: [0])
        #expect(ui.log.contains { $0.hasPrefix("choose: Run this download list? (3000 downloads)") })
    }

    @Test func aNameWithALineBreakIsNotAddedToAList() throws {
        // A server offers a file whose name would read as two lines of a list.
        try box.file("srv/pub/payload\u{2028}move:~x -> ftp:~~evil~k", "p")
        quickConnect("ftp://\(address)/pub")
        let name = try #require(left.names.first { $0.hasPrefix("payload") })
        let list = box.url("list.txt")
        left.moveCursor(toName: name)
        ui.promptAnswers = [.text(list.path)]
        commands.perform(.ftpAddToList)
        #expect(ui.log.last == "inform: 1 of the files were not added to the download list.")
        #expect((box.read("list.txt") ?? "").isEmpty)
        left.moveCursor(toName: "report.txt")
        ui.promptAnswers = [.text(list.path)]
        commands.perform(.ftpAddToList)
        #expect(DownloadList.parse(box.read("list.txt") ?? "") == [.download(source: "ftp://\(address)/pub/report.txt", target: box.url("other/report.txt").path)])
    }

    // MARK: Secrets

    @Test func theQuickConnectPasswordIsKeptOnlyWhenTheBoxStaysTicked() throws {
        server.options.user = "anna"
        server.options.password = "s3cret-pw"
        for (keeps, name) in [(false, "No password"), (true, "With password")] {
            quickConnect("ftp://anna:s3cret-pw@\(address)/pub")
            #expect(left.model.directory == url("/pub"))
            // Disconnect, Yes to saving, the details with the box as the round wants it.
            ui.choiceAnswers = [0]
            ui.formAnswers = [.values(["name": .text(name), "savePassword": .flag(keeps)])]
            commands.perform(.ftpDisconnect)
            plugin.waitForStoredSecrets()
            let saved = try #require(plugin.connections.first { $0.name == name })
            #expect(passwords.password(for: PasswordVault.account(of: saved)) == (keeps ? "s3cret-pw" : nil))
        }
        #expect(!passwords.accounts.contains { $0.count == 36 }, "nothing is kept under an identifier alone")
        #expect(String(decoding: try JSONEncoder().encode(plugin.connections), as: UTF8.self).range(of: "s3cret") == nil)
    }

    @Test func aPasswordBelongsToItsServerAndUser() throws {
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
        planted.port = 2121
        foreign.connections = [planted]
        #expect(foreign.vault.password(for: planted.profile) == nil)
        // A profile that names a connection the store does not have gets nothing.
        #expect(store.vault.password(for: ConnectionProfile(key: connection.key, savedID: UUID(), user: "anna")) == nil)

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
        #expect(passwords.accounts.filter { $0.contains(connection.id.uuidString) }.isEmpty)
    }

    @Test func passwordsOfAnEarlierVersionAreMovedOnce() throws {
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

    @Test func certificatesInTheSettingsAreNotBelieved() throws {
        // A settings file that came with a fingerprint for a server: it is not trusted, and it is removed.
        let settings = MemorySettings()
        settings.set(["files.example.com": ["AA:BB"]], forKey: "network.trustedCertificates")
        let plugin = NetworkPlugin(launchesApplications: false, passwords: passwords)
        _ = TestBench(plugins: [plugin], fileSystems: [LocalFileSystem()], left: box.url("local"), right: box.url("other"), settings: settings)
        let trust = plugin.center.environment.trust
        trust.prepare()
        #expect(!trust.isAccepted("AA:BB", for: "files.example.com"))
        #expect((settings.value([String: [String]].self, forKey: "network.trustedCertificates") ?? [:]).isEmpty)

        // What the user accepts for good is kept with the passwords, and found there by the next start.
        let vault = PasswordVault(store: passwords)
        vault.setTrusted(["CC:DD"], for: "Files.Example.com", adding: true)
        vault.setTrusted(["EE:FF"], for: "files.example.com", adding: true)
        #expect(vault.trustedCertificates() == ["files.example.com": ["CC:DD", "EE:FF"]] && vault.hasTrusted(for: "FILES.example.com"))
        // A changed certificate takes the place of the old ones.
        vault.setTrusted(["11:22"], for: "files.example.com", adding: false)
        #expect(vault.trustedCertificates() == ["files.example.com": ["11:22"]])
        let next = NetworkPlugin(launchesApplications: false, passwords: passwords)
        _ = TestBench(plugins: [next], fileSystems: [LocalFileSystem()], left: box.url("local"), right: box.url("other"), settings: MemorySettings())
        next.center.environment.trust.prepare()
        #expect(next.center.environment.trust.isAccepted("11:22", for: "files.example.com"))
    }

    @Test func theDialogForAChangedCertificateNeedsMoreThanAButton() throws {
        let environment = plugin.center.environment
        let profile = ConnectionProfile(key: ServerKey(scheme: "ftps", host: "files.example.com"))
        let old = CertificateInfo(fingerprint: "AA:BB", subject: "files", problem: "self-signed")
        let new = CertificateInfo(fingerprint: "CC:DD", subject: "files", problem: "self-signed")
        // A first visit: the usual question, kept for good when the user says so.
        ui.formAnswers = [.values(["always": .flag(true)])]
        #expect(environment.askToTrust(profile, old))
        plugin.waitForStoredSecrets()
        #expect(environment.trust.isAccepted("AA:BB", for: "files.example.com"))

        // The certificate changed: another dialog, which says so and shows both fingerprints.
        ui.formAnswers = [.accept]
        #expect(!environment.askToTrustChanged(profile, new, ["AA:BB"]), "the button alone is no consent")
        #expect(ui.log.last == "form: The server's certificate has changed!")
        let box = try #require(ui.forms.last?.first)
        #expect(box.label.contains("checked the new fingerprint"))
        #expect(environment.trust.fingerprints(for: "files.example.com") == ["AA:BB"])
        ui.formAnswers = [.cancel]
        #expect(!environment.askToTrustChanged(profile, new, ["AA:BB"]))
        // With the box ticked the new one replaces the old, here and where it is stored.
        ui.formAnswers = [.values(["verified": .flag(true)])]
        #expect(environment.askToTrustChanged(profile, new, ["AA:BB"]))
        plugin.waitForStoredSecrets()
        #expect(environment.trust.fingerprints(for: "files.example.com") == ["CC:DD"])
        #expect(PasswordVault(store: passwords).trustedCertificates() == ["files.example.com": ["CC:DD"]])
    }

    @Test func noMessageShowsAPassword() throws {
        // A mount that fails, and an address that is none.
        commands.perform(.netConnect, .text("smb://anna:s3cret-pw@nas.invalid/share"))
        commands.perform(.netConnect, .text("gopher://anna:s3cret-pw@old.invalid/x"))
        quickConnect("ftp://anna:s3cret-pw@bad host/")
        #expect(!ui.log.contains { $0.contains("s3cret") }, "\(ui.log)")
        #expect(ui.log.contains("inform: gopher://anna@old.invalid/x is not the address of a server."))
        let message = VolumeError(message: "The server \(ServerAddress.removingPassword(from: "smb://anna:s3cret-pw@nas.invalid/share")) could not be connected: x.")
        #expect(message.localizedDescription.contains("smb://anna@nas.invalid/share"))
        // The stored proposal never holds one either.
        #expect(settings.text("network.lastServerAddress", default: "") == "smb://anna@nas.invalid/share")
    }
}
