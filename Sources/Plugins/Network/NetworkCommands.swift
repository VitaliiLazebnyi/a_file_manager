import AFMContracts
import AFMKernel
import Foundation

/// The behaviour behind the Net menu: the connection dialogs, connecting and disconnecting,
/// the download list and the network volumes.
///
/// **Threading.** Commands run on the main thread and only talk to the user and the panels
/// there. Everything that reaches a server or a disk runs in a job (`kernel.jobs.run`) or on a
/// background queue; the questions connections ask in the middle (a password, a certificate)
/// come back to the main thread through `Kernel.askUser`.
@MainActor
final class NetworkCommands {
    private let kernel: Kernel
    private let center: ConnectionCenter
    private let store: ConnectionStore
    private let mounter: any VolumeMounter?
    /// Where each panel was before it showed a server, to return there on Disconnect.
    private var lastLocal: [ObjectIdentifier: URL] = [:]
    private var panelSubscription: AnyObject?

    init(kernel: Kernel, center: ConnectionCenter, store: ConnectionStore, mounter: any VolumeMounter?) {
        self.kernel = kernel
        self.center = center
        self.store = store
        self.mounter = mounter
        panelSubscription = kernel.panelEvents.subscribe { [weak self] event, panel in
            guard case .locationChanged = event, panel.model.directory.isFileURL else { return }
            self?.lastLocal[ObjectIdentifier(panel)] = panel.model.directory
        }
    }

    private var ui: any UserInteraction { kernel.ui }
    private var source: any PanelHandle { kernel.panels.source }
    var canEject: Bool { mounter != nil }

    // MARK: Questions asked by connections

    /// Routes the questions of the connections to the user. They are asked from the thread
    /// that connects and answered on the main thread. Nothing here touches the Keychain: what
    /// is to be stored is handed to the vault, which works on a queue of its own.
    ///
    /// The questions handed to `askUser` are marked `@Sendable`: they hold only values that are
    /// safe on any thread, and without the mark the compiler cannot check them.
    func connectQuestions() {
        let (kernel, store, center) = (self.kernel, self.store, self.center)
        let environment = center.environment
        let vault = store.vault
        environment.askCredentials = { profile, message in
            kernel.askUser { @Sendable ui -> Credentials? in
                // The title names the connection, so password managers can fill the dialog in.
                var fields: [FormField] = [
                    .text("user", "User name:", profile.user ?? ""), .password("password", "Password:")
                ]
                if profile.savedID != nil {
                    fields.append(.checkbox("save", "Remember the password in the Keychain", true))
                }
                let detail =
                    message.isEmpty
                    ? "User name and password for \(profile.key.description)" : "The server answered: \(message)"
                guard let answer = ui.form(profile.title, detail: detail, fields: fields, buttons: ["OK"]),
                    !answer.text("user").isEmpty
                else { return nil }
                // Stored only once the server has accepted it (`rememberPassword`).
                return Credentials(
                    user: answer.text("user"), password: answer.text("password"),
                    remember: profile.savedID != nil && answer.flag("save"))
            }
        }
        environment.rememberPassword = { profile, password in
            guard let id = profile.savedID, let user = profile.user else { return }
            DispatchQueue.main.async {
                // Under the name of the connection as it is saved: a user name typed at the login
                // fills an empty one in, and a password for another user is not stored for this one.
                guard var saved = store.connections.first(where: { $0.id == id }),
                    !saved.anonymous || saved.user.isEmpty
                else { return }
                if saved.user.isEmpty {
                    (saved.user, saved.anonymous) = (user, false)
                    store.save(saved)
                }
                guard saved.user == user, saved.key == profile.key else { return }
                vault.setPassword(password, for: saved)
            }
        }
        environment.askToConnect = { profile in
            kernel.askUser { @Sendable ui -> Bool in
                let how =
                    profile.key.scheme == "sftp"
                    ? "A secure shell login as \(profile.user ?? NSUserName()) would be made, with the keys and the configuration of your account."
                    : profile.user.map { "A login as \($0) would be made." } ?? "An anonymous login would be made."
                let detail = """
                    A location on this server was opened, but you did not choose to connect to it: \
                    the address may come from a tab, a list or a link.

                    \(how)
                    """
                // Return is Cancel: nobody asked for this connection.
                return ui.choose(
                    "Connect to \(profile.key.description)?", detail: detail, buttons: ["Connect", "Cancel"],
                    style: .warning,
                    defaultButton: 1) == 0
            }
        }
        environment.askToSendPasswordUnprotected = { profile in
            let host = profile.key.host
            if kernel.settings.value([String].self, forKey: NetworkSettings.unprotectedHosts)?.contains(host) == true {
                return true
            }
            return kernel.askUser { @Sendable ui -> Bool in
                let detail = """
                    \(profile.key.description) is a plain FTP connection. The password travels unencrypted, \
                    and anyone on the way can read it, and the files.

                    If the server offers it, use FTP over TLS or SFTP instead.
                    """
                guard
                    let answer = ui.form(
                        "Send the password unencrypted?", detail: detail,
                        fields: [.checkbox("always", "Do not ask again for this server", false)],
                        buttons: ["Send Unencrypted"])
                else { return false }
                if answer.flag("always") {
                    let known = kernel.settings.value([String].self, forKey: NetworkSettings.unprotectedHosts) ?? []
                    kernel.settings.set(
                        Array((known.filter { $0 != host } + [host]).suffix(200)),
                        forKey: NetworkSettings.unprotectedHosts)
                }
                return true
            }
        }
        environment.askToTrust = { profile, certificate in
            kernel.askUser { @Sendable ui -> Bool in
                let detail = """
                    The certificate was not signed by a trusted party!
                    Continue anyway?

                    Connected to: \(profile.key.host):\(profile.key.port)
                    SHA-256 fingerprint: \(certificate.fingerprint)
                    Cert subject: \(certificate.subject)
                    \(certificate.problem)
                    """
                guard
                    let answer = ui.form(
                        "SSL", detail: detail, fields: [.checkbox("always", "Always trust this server", false)],
                        buttons: ["Yes"])
                else { return false }
                environment.trust.accept(certificate.fingerprint, for: profile.key.host)
                if answer.flag("always") {
                    vault.setTrusted([certificate.fingerprint], for: profile.key.host, adding: true)
                }
                return true
            }
        }
        environment.askToTrustChanged = { profile, certificate, known in
            // Whether the old certificate was accepted for good is read here, on the connecting thread.
            let wasStored = vault.hasTrusted(for: profile.key.host)
            return kernel.askUser { @Sendable ui -> Bool in
                let detail = """
                    WARNING: THE CERTIFICATE OF THIS SERVER HAS CHANGED.

                    \(profile.key.host):\(profile.key.port) now shows a certificate that is not the one you accepted \
                    for it before, and that the system does not trust either. Somebody may be \
                    intercepting the connection to read your password and your files. It is also \
                    possible that the server's certificate was renewed.

                    Do not go on unless you have checked the new fingerprint with whoever runs the server.

                    Accepted before (SHA-256):
                    \(known.joined(separator: "\n"))

                    Shown now (SHA-256):
                    \(certificate.fingerprint)
                    Cert subject: \(certificate.subject)
                    \(certificate.problem)
                    """
                let fields: [FormField] = [
                    .checkbox(
                        "verified", "I have checked the new fingerprint. Trust it in place of the old certificate.",
                        false)
                ]
                // Only the ticked box is consent; the button alone, or Return, is not.
                guard
                    let answer = ui.form(
                        "The server's certificate has changed!", detail: detail, fields: fields,
                        buttons: ["Replace the Trusted Certificate"]), answer.flag("verified")
                else { return false }
                // The old certificate is trusted no longer, here and where it was stored.
                environment.trust.replace(with: certificate.fingerprint, for: profile.key.host)
                if wasStored { vault.setTrusted([certificate.fingerprint], for: profile.key.host, adding: false) }
                return true
            }
        }
        environment.askSecret = { profile, question, isSecret in
            kernel.askUser { @Sendable ui -> String? in
                if !isSecret {
                    // The secure shell asks to confirm a host key it has not seen.
                    // Return is No: a key is accepted on purpose.
                    return ui.choose(
                        profile.title, detail: question, buttons: ["Yes", "No"], style: .warning, defaultButton: 1)
                        == 0 ? "yes" : "no"
                }
                return ui.form(profile.title, detail: question, fields: [.password("secret", "")], buttons: ["OK"])?
                    .text("secret")
            }
        }
    }

    // MARK: Connecting

    /// Opens the connection in the source panel (spec 11 › Connecting). The login runs as a
    /// job with a Cancel button; the panel follows when it succeeded.
    func connect(
        _ profile: ConnectionProfile, path: String? = nil, localDirectory: String? = nil, saved: SavedConnection? = nil
    ) {
        let (center, key, panel) = (self.center, profile.key, source)
        if panel.model.directory.isFileURL { lastLocal[ObjectIdentifier(panel)] = panel.model.directory }
        // The user asked for this connection; no question whether to connect at all.
        if !center.isConnected(key) { center.announce(profile, chosen: true) }
        kernel.jobs.run(
            title: "Connect to \(profile.title)",
            work: { monitor -> Result<String, any Error> in
                monitor.report(
                    JobProgress(
                        lines: [
                            "Connect to: \(key.description)",
                            "User name: \(profile.user ?? (profile.anonymous ? "anonymous" : ""))"
                        ],
                        itemsDone: 0, itemsTotal: 0))
                return Result { try center.connect(key, cancellation: monitor.cancellation) }
            },
            completion: { [kernel, store] result in
                switch result {
                case .success(let home):
                    if let saved { store.lastUsed = saved.id }
                    panel.show(key.url(path: path ?? profile.remoteDirectory ?? home))
                    // The other panel goes to the local folder that belongs to the connection.
                    if let localDirectory, !localDirectory.isEmpty {
                        let other = panel === kernel.panels.left ? kernel.panels.right : kernel.panels.left
                        other.show(
                            URL(
                                fileURLWithPath: NSString(string: localDirectory).expandingTildeInPath,
                                isDirectory: true))
                    }

                case .failure(let error):
                    // Returns at once: what waits for the server is done in the background.
                    center.disconnect(key)
                    if case NetworkError.cancelled = error { return }
                    kernel.ui.report(error, title: "Connect failed!")
                }
            })
    }

    /// `FTPOPEN session` and `FTPOPEN session|/subdir`.
    func open(saved text: String) {
        let parts = text.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let name = parts.first, let connection = store.connection(named: name) else {
            ui.inform("There is no saved connection named \(text).", detail: "", style: .warning)
            return
        }
        // `|*/dir` asks for the active panel, which is where connections open anyway.
        let path = parts.count > 1 ? String(parts[1].drop(while: { $0 == "*" })) : nil
        connect(connection.profile, path: path, localDirectory: connection.localDirectory, saved: connection)
    }

    /// Ctrl+N: quick connect by host or URL (spec 11 › Quick connect).
    func quickConnect() {
        let history = store.history
        var fields: [FormField] = [.text("address", "Connect to (host or URL):", history.first ?? "")]
        if history.count > 1 { fields.append(.choice("recent", "Recent:", ["—"] + history)) }
        fields.append(.checkbox("anonymous", "Anonymous connection", true))
        guard
            let answer = ui.form(
                "FTP: new connection",
                detail: "host, host:port, user@host or ftp://, ftps://, ftpes://, ftpis://, sftp://…",
                fields: fields, buttons: ["OK"])
        else { return }
        let recent = answer.index("recent")
        let text = recent > 0 && history.indices.contains(recent - 1) ? history[recent - 1] : answer.text("address")
        guard let address = ServerAddress(text) else {
            // What was typed may hold a password; it is not shown again.
            ui.inform(
                "\(ServerAddress.removingPassword(from: text)) is not a server address.", detail: "", style: .warning)
            return
        }
        store.remember(address: address)
        // A user name in the address means: not as a guest.
        let anonymous = answer.flag("anonymous") && address.user == nil && address.scheme != "sftp"
        let user = address.user ?? (address.scheme == "sftp" ? NSUserName() : nil)
        connect(
            ConnectionProfile(
                key: address.key, tls: address.tls, user: user, password: address.password, anonymous: anonymous),
            path: address.hasPath ? address.path : nil)
    }

    // MARK: The list of saved connections

    /// Ctrl+F: the saved connections (spec 11 › "Connect to ftp server" dialog).
    func showConnections() {
        var selected = store.connections.firstIndex { $0.id == store.lastUsed } ?? 0
        while true {
            let connections = store.connections
            let rows = connections.isEmpty ? ["(no saved connections)"] : connections.map(\.listTitle)
            guard
                let answer = ui.form(
                    "Connect to FTP server", detail: "Connect to:",
                    fields: [.list("connection", "", rows, selected: selected)],
                    buttons: ["Connect", "New Connection…", "New URL…", "Duplicate Entry…", "Edit…", "Delete"])
            else { return }
            let row = answer.index("connection")
            let chosen = connections.indices.contains(row) ? connections[row] : nil
            selected = max(0, row)
            switch answer.button {
            case 0:
                guard let chosen else { continue }
                connect(chosen.profile, localDirectory: chosen.localDirectory, saved: chosen)
                return

            case 1:
                if let created = edit(SavedConnection(), isNew: true) {
                    selected = store.connections.firstIndex { $0.id == created.id } ?? selected
                }

            case 2:
                quickConnect()
                return

            case 3:
                guard let chosen else { continue }
                var copy = chosen
                copy.id = UUID()
                copy.name = chosen.name + " (2)"
                // The copy takes the password along, to whatever host and user it is saved with.
                _ = edit(copy, isNew: true, passwordOf: chosen)

            case 4:
                if let chosen { _ = edit(chosen, isNew: false) }

            default:
                guard let chosen,
                    ui.choose(
                        "Delete the connection \(chosen.name)?", detail: "", buttons: ["Delete", "Cancel"],
                        style: .warning) == 0
                else {
                    continue
                }
                store.delete(chosen)
                selected = max(0, min(selected, store.connections.count - 1))
            }
        }
    }

    /// "FTP: connection details" (spec 11). Returns what was saved; nil on Cancel.
    ///
    /// The password is kept by the vault under the connection's server and login. It is never
    /// read here (the Keychain may make the main thread wait): an empty field leaves what is
    /// stored as it is, and the vault moves it along when the host or user was changed.
    /// `offered` is a password that is known already and is stored when the field is left
    /// empty (the one a quick connection was made with); `passwordOf` names the connection
    /// whose stored password this one takes over (the original of a copy).
    @discardableResult
    func edit(
        _ original: SavedConnection, isNew: Bool, offered: String? = nil, passwordOf source: SavedConnection? = nil
    ) -> SavedConnection? {
        var connection = original
        while true {
            let fields: [FormField] = [
                .text("name", "Session:", connection.name),
                .text("host", "Host name[:Port]:", connection.hostText),
                .choice(
                    "kind", "Protocol:", SavedConnection.Kind.allCases.map(\.title), selected: connection.kind.rawValue
                ),
                .checkbox("anonymous", "Anonymous login (e-mail address as password)", connection.anonymous),
                .text("user", "User name:", connection.user),
                .password(
                    "password",
                    isNew && offered == nil && source == nil
                        ? "Password (empty: ask when connecting):"
                        : "Password (empty: unchanged):"),
                .checkbox("savePassword", "Keep the password in the macOS Keychain", true),
                .note("Passwords are stored in the Keychain, never in the settings; a master password is not needed."),
                .text("remote", "Remote dir:", connection.remoteDirectory),
                .text("local", "Local dir:", connection.localDirectory),
                .checkbox("passive", "Use passive mode for transfers (like a web browser)", connection.passive),
                .choice(
                    "encoding", "Encoding of file names:", NameEncoding.allCases.map(\.title),
                    selected: connection.encoding.rawValue),
                .choice(
                    "listing", "Directory listings:", SavedConnection.Listing.allCases.map(\.title),
                    selected: connection.listing.rawValue),
                .text("commands", "Send commands (separated by ;):", connection.initCommands)
            ]
            guard let answer = ui.form("FTP: connection details", detail: "", fields: fields, buttons: ["OK"]) else {
                return nil
            }
            connection.name = answer.text("name").trimmingCharacters(in: .whitespaces)
            connection.anonymous = answer.flag("anonymous")
            connection.user = answer.text("user")
            connection.remoteDirectory = answer.text("remote").trimmingCharacters(in: .whitespaces)
            connection.localDirectory = answer.text("local").trimmingCharacters(in: .whitespaces)
            connection.passive = answer.flag("passive")
            connection.encoding = NameEncoding(rawValue: answer.index("encoding")) ?? .automatic
            connection.listing = SavedConnection.Listing(rawValue: answer.index("listing")) ?? .automatic
            connection.initCommands = answer.text("commands")
            let kind = SavedConnection.Kind(rawValue: answer.index("kind")) ?? .ftp
            guard connection.setHost(answer.text("host"), kind: kind) else {
                ui.inform(
                    "\(ServerAddress.removingPassword(from: answer.text("host"))) is not a host name.", detail: "",
                    style: .warning)
                continue
            }
            if connection.name.isEmpty { connection.name = connection.host }
            if store.connections.contains(where: {
                $0.id != connection.id && $0.name.caseInsensitiveCompare(connection.name) == .orderedSame
            }) {
                ui.inform("A connection named \(connection.name) already exists.", detail: "", style: .warning)
                continue
            }
            let vault = store.vault
            let typed = answer.text("password")
            let keeps = answer.flag("savePassword") && !connection.anonymous
            // What was stored for the connection as it was, under its old host and user.
            let before = source ?? (isNew ? nil : original)
            store.save(connection)
            if !keeps {
                // Unticked: no password is kept, whatever was typed or known.
                if let before, source == nil { vault.setPassword(nil, for: before) }
                vault.setPassword(nil, for: connection)
            } else if !typed.isEmpty {
                if let before, source == nil { vault.carryPassword(from: before, to: connection, removing: true) }
                vault.setPassword(typed, for: connection)
            } else if let offered {
                vault.setPassword(offered, for: connection)
            } else if let before {
                // Unchanged: it follows the connection to its new host or user, or to the copy.
                vault.carryPassword(from: before, to: connection, removing: source == nil)
            }
            return connection
        }
    }

    // MARK: Disconnecting

    /// Ctrl+Shift+F (spec 11 › Disconnecting): closes the connection of the source panel, or
    /// of the other panel, or the one the user picks, and returns the panels that showed it to
    /// the local folder they came from.
    func disconnect() {
        let connected = center.connected
        guard !connected.isEmpty else { return }
        let panels = [source, kernel.panels.target]
        var profile = panels.lazy.compactMap { panel in
            ServerKey(panel.model.directory).flatMap { key in connected.first { $0.key == key } }
        }.first
        if profile == nil, connected.count == 1 { profile = connected[0] }
        if profile == nil {
            guard
                let row = ui.pickRow(
                    "FTP Disconnect", detail: "Close the connection to:", rows: connected.map(\.title),
                    button: "Disconnect")
            else { return }
            profile = connected[row]
        }
        guard let profile else { return }
        let key = profile.key

        // A quick connection offers to be saved first.
        if profile.savedID == nil, kernel.settings.flag(NetworkSettings.askToSave, default: true) {
            switch ui.choose(
                "Current session not saved, save?", detail: profile.key.description, buttons: ["Yes", "No", "Cancel"],
                style: .information)
            {
            case 0:
                var connection = SavedConnection()
                connection.kind = SavedConnection.Kind(scheme: key.scheme, tls: profile.tls)
                connection.host = key.host
                connection.port = key.port == connection.kind.defaultPort ? nil : key.port
                connection.anonymous = profile.anonymous || profile.user == "anonymous"
                connection.user = connection.anonymous ? "" : profile.user ?? ""
                connection.remoteDirectory = center.lastPath(on: key) ?? ""
                // The password the connection was made with is kept only if the box in the dialog stays ticked.
                edit(connection, isNew: true, offered: connection.anonymous ? nil : profile.password)

            case 1: break
            default: return
            }
        }
        for panel in kernel.panels.all where ServerKey(panel.model.directory) == key {
            panel.show(lastLocal[ObjectIdentifier(panel)] ?? FileManager.default.homeDirectoryForCurrentUser)
        }
        // Returns at once: saying goodbye waits for the server and is done in the background.
        center.disconnect(key)
    }

    // MARK: Options of the session

    func toggleHiddenFiles() {
        if kernel.commands[.showHidden] != nil {
            kernel.commands.perform(.showHidden)
        } else {
            source.model.setShowHidden(!source.model.showHidden)
            source.reload()
        }
    }

    /// Ctrl+Shift+M (spec 11 › Transfer modes).
    func selectTransferMode() {
        let current = kernel.settings.index(NetworkSettings.transferMode, default: 0)
        guard
            let answer = ui.form(
                "FTP transfer mode", detail: "Text mode converts line ends; binary transfers files unchanged.",
                fields: [.choice("mode", "Transfer mode:", TransferMode.allCases.map(\.title), selected: current)],
                buttons: ["OK"])
        else { return }
        kernel.settings.set(answer.index("mode"), forKey: NetworkSettings.transferMode)
        center.environment.options.values = NetworkSettings.values(from: kernel.settings)
    }

    // MARK: Download list

    private func askForList(_ title: String) -> URL? {
        let proposal = kernel.settings.text(
            NetworkSettings.listName, default: "~/Downloads/" + DownloadList.defaultName)
        guard let text = ui.prompt(title, value: proposal)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return nil
        }
        kernel.settings.set(text, forKey: NetworkSettings.listName)
        let location = kernel.fileSystems.location(
            from: text,
            relativeTo: source.model.directory.isFileURL
                ? source.model.directory
                : FileManager.default.homeDirectoryForCurrentUser)
        return location.isFileURL ? location : nil
    }

    /// The text of a list file. A list is a small text; a file that is no plain file, or
    /// larger than `DownloadList.largestFile`, is not read.
    nonisolated static func readList(_ list: URL) throws -> String {
        let values = try list.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw VolumeError(message: "\(list.path) is not a file.") }
        let limit = DownloadList.largestFile
        guard (values.fileSize ?? 0) <= limit else {
            throw VolumeError(message: "\(list.path) is larger than \(limit >> 20) MB, which no download list is.")
        }
        let handle = try FileHandle(forReadingFrom: list)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else {
            throw VolumeError(message: "\(list.path) is larger than \(limit >> 20) MB, which no download list is.")
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else {
            throw VolumeError(message: "\(list.path) is not a text file.")
        }
        return text
    }

    /// Download later: writes the marked files of the server into the list file, each with
    /// the place it is to go to (spec 11 › Download later). The lines are made in the job, not
    /// here: with very many files that is work the main thread must not do.
    func addToDownloadList() {
        let items = source.model.operands()
        guard !items.isEmpty, let list = askForList("File name of download list:") else { return }
        let fileSystems = kernel.fileSystems
        let targetDirectory = kernel.panels.target.model.directory
        kernel.jobs.run(
            title: "Download list:",
            work: { monitor -> Result<Int, any Error> in
                Result {
                    var text =
                        FileManager.default.fileExists(atPath: list.path) ? try Self.readList(list) : ""
                    if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
                    var refused = 0
                    for item in items {
                        if monitor.cancellation.isCancelled { throw NetworkError.cancelled }
                        let source = fileSystems.displayPath(item.url)
                        let target = targetDirectory.isFileURL ? targetDirectory.appending(name: item.name).path : nil
                        // A name with a line break would be read back as a line of its own, with whatever it says.
                        guard DownloadList.canHold(source: source, target: target) else {
                            refused += 1
                            continue
                        }
                        text += DownloadList.line(source: source, target: target) + "\n"
                    }
                    guard text.utf8.count <= DownloadList.largestFile else {
                        throw VolumeError(
                            message: "The download list would become larger than \(DownloadList.largestFile >> 20) MB.")
                    }
                    try text.write(to: list, atomically: true, encoding: .utf8)
                    return refused
                }
            },
            completion: { [kernel] result in
                switch result {
                case .failure(NetworkError.cancelled): break
                case .failure(let error): kernel.ui.report(error, title: "The download list cannot be written!")

                case .success(let refused) where refused > 0:
                    kernel.ui.inform(
                        "\(refused) of the files were not added to the download list.",
                        detail: "Their names contain a line break or the list's separator, which a list cannot hold.",
                        style: .warning)

                case .success: break
                }
                kernel.panels.refresh([list.deletingLastPathComponent()])
            })
    }

    /// Works through a list file, one line after the other, with the usual copy job for each
    /// (spec 11 › Net › FTP Download From List…). Lines without a target go to the folder of
    /// the target panel.
    ///
    /// A list file may come from anybody and says what is copied where, so nothing runs
    /// before the user has seen what the list would do and agreed (`ListPlan.preview`).
    func downloadFromList() {
        guard let list = askForList("File name of download list:") else { return }
        guard let transfers = kernel.services.find((any FileTransferService).self) else {
            ui.inform("Copying files is not available.", detail: "", style: .warning)
            return
        }
        let target = kernel.panels.target.model.directory
        let base = target.isFileURL ? target : FileManager.default.homeDirectoryForCurrentUser
        kernel.jobs.run(
            title: "Download list:",
            work: { _ in
                Result { try Self.readList(list) }
            },
            completion: { [kernel] result in
                let text: String
                switch result {
                case .success(let read): text = read
                case .failure(let error): return kernel.ui.report(error, title: "The download list cannot be read!")
                }
                let plan = ListPlan(actions: DownloadList.parse(text), base: base, fileSystems: kernel.fileSystems)
                guard !plan.steps.isEmpty else {
                    return kernel.ui.inform(
                        "The download list \(list.path) holds nothing that can be carried out.",
                        detail: ListPlan.shortened(plan.skipped), style: .warning)
                }
                let preview = plan.preview(of: list)
                guard
                    kernel.ui.choose(
                        preview.message, detail: preview.detail, buttons: ["Run the List", "Cancel"],
                        style: plan.touchesLocalFiles ? .critical : .warning) == 0
                else { return }
                ListRun(plan: plan, kernel: kernel, transfers: transfers).next()
            })
    }

    // MARK: Network volumes

    /// Connect to Server (spec 11 › Map a network drive, adapted): an address of a file server
    /// is mounted by the system and shown in the source panel; an FTP or SFTP address opens a
    /// connection of this program.
    func connectToServer(_ given: String?) {
        // An address stored by an older version may still carry a password; it is not shown again.
        let proposal = ServerAddress.removingPassword(
            from: kernel.settings.text(NetworkSettings.lastServer, default: "smb://"))
        guard
            let text =
                (given
                ?? ui.prompt(
                    "Connect to Server", value: proposal,
                    detail: "smb://, afp://, nfs://, https:// (WebDAV), or ftp://, ftps://, sftp://"))?
                .trimmingCharacters(in: .whitespaces), !text.isEmpty
        else { return }
        if let address = ServerAddress(text), text.contains("://") {
            let user = address.user ?? (address.scheme == "sftp" ? NSUserName() : nil)
            connect(
                ConnectionProfile(
                    key: address.key, tls: address.tls, user: user, password: address.password, anonymous: user == nil
                ),
                path: address.hasPath ? address.path : nil)
            return
        }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
            ServerSchemes.mountable.contains(scheme), url.host != nil
        else {
            // What was typed may hold a password; it is not shown again.
            ui.inform(
                "\(ServerAddress.removingPassword(from: text)) is not the address of a server.", detail: "",
                style: .warning)
            return
        }
        // The address is offered again next time; a password in it is not kept.
        kernel.settings.set(ServerAddress.removingPassword(from: text), forKey: NetworkSettings.lastServer)
        guard let mounter else { return }
        let panel = source
        kernel.jobs.run(
            title: "Connect to \(url.host ?? "server")",
            work: { monitor in
                Result { try mounter.mount(url, cancellation: monitor.cancellation) }
            },
            completion: { [kernel] result in
                switch result {
                case .success(let volumes):
                    if let volume = volumes.first { panel.show(volume) }

                case .failure(NetworkError.cancelled):
                    break

                case .failure(let error):
                    kernel.ui.report(error, title: "Connect failed!")
                }
            })
    }

    /// Ejects the volume the source panel shows; the panels leave it first.
    func ejectVolume() {
        guard let mounter, let volume = ServerSchemes.mountedVolume(of: source.model.directory) else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let inside = kernel.panels.all.filter {
            $0.model.directory.isSameLocation(as: volume) || $0.model.directory.isInside(volume)
        }
        var leaving = inside.count
        let eject = { [kernel] in
            _ = kernel.jobs.run(
                title: "Eject \(volume.lastPathComponent)", work: { _ in Result { try mounter.unmount(volume) } },
                completion: { result in
                    if case .failure(let error) = result {
                        kernel.ui.report(error, title: "\(volume.lastPathComponent) cannot be ejected!")
                    }
                })
        }
        if inside.isEmpty {
            eject()
            return
        }
        for panel in inside {
            panel.show(home, focus: nil, history: .record) { _ in
                leaving -= 1
                if leaving == 0 { eject() }
            }
        }
    }
}

/// What a download list would do, worked out before anything is done: the lines as transfers
/// between two locations, and the lines that are not carried out. Main thread; it only reads
/// text (no server and no disk is asked).
struct ListPlan {
    enum Kind { case download, copy, move }

    struct Step {
        let kind: Kind
        let from: URL
        let to: URL
        /// As the user is shown it.
        let text: String
    }

    enum Item {
        case transfer(Step)
        case pause(TimeInterval)
    }

    private(set) var items: [Item] = []
    /// The lines that are not carried out, each with the reason.
    private(set) var skipped: [String] = []

    var steps: [Step] {
        items.compactMap { item in
            if case .transfer(let step) = item { return step }
            return nil
        }
    }

    /// True when a line sends away, moves or copies a file that is on this Mac: more than a
    /// download list is expected to do.
    var touchesLocalFiles: Bool { steps.contains { $0.kind != .download } }

    init(actions: [DownloadList.Action], base: URL, fileSystems: FileSystemRegistry) {
        for action in actions {
            let (kind, source, target): (Kind, String, String?)
            switch action {
            case .pause(let seconds):
                items.append(.pause(seconds))
                continue

            case .unsupported(let line):
                skipped.append(line)
                continue

            case .download(let from, let to): (kind, source, target) = (.download, from, to)
            case .copy(let from, let to): (kind, source, target) = (.copy, from, to)
            case .move(let from, let to): (kind, source, target) = (.move, from, to)
            }
            let from = fileSystems.location(from: source, relativeTo: base)
            let to =
                target.map { fileSystems.location(from: $0, relativeTo: base) }
                ?? base.appending(name: from.lastPathComponent)
            guard (try? fileSystems.provider(for: from)) != nil, (try? fileSystems.provider(for: to)) != nil,
                !from.lastPathComponent.isEmpty, !to.lastPathComponent.isEmpty
            else {
                skipped.append(source)
                continue
            }
            // A plain line fetches from a server to this Mac. Anything else must say so (`put:`, `copy:`, `move:`).
            if kind == .download, from.isFileURL || !to.isFileURL {
                skipped.append(
                    "\(source) (not a download from a server to this Mac; such a line must start with put:, copy: or move:)"
                )
                continue
            }
            let verb =
                kind == .move
                ? "Move (the source is deleted)"
                : kind == .copy ? (from.isFileURL && !to.isFileURL ? "Upload" : "Copy") : "Download"
            items.append(
                .transfer(
                    Step(
                        kind: kind, from: from, to: to,
                        text: "\(verb): \(fileSystems.displayPath(from))  →  \(fileSystems.displayPath(to))")))
        }
    }

    /// At most this many lines are shown in a message; a list may have a hundred thousand.
    static let shownLines = 20

    static func shortened(_ lines: [String]) -> String {
        let shown = lines.prefix(shownLines).map { $0.count > 300 ? String($0.prefix(300)) + "…" : $0 }
        return (shown + (lines.count > shownLines ? ["… and \(lines.count - shownLines) more"] : [])).joined(
            separator: "\n")
    }

    /// What the user is asked to agree to before the list runs.
    func preview(of list: URL) -> (message: String, detail: String) {
        let steps = steps
        let downloads = steps.filter { $0.kind == .download }.count
        let moves = steps.filter { $0.kind == .move }.count
        let copies = steps.count - downloads - moves
        var counts: [String] = []
        if downloads > 0 { counts.append("\(downloads) downloads") }
        if copies > 0 { counts.append("\(copies) uploads or copies") }
        if moves > 0 { counts.append("\(moves) moves") }
        var detail = "\(list.path) says:\n\n" + Self.shortened(steps.map(\.text))
        if touchesLocalFiles {
            detail +=
                "\n\nThis list does more than download: it sends, copies or moves files that are on this Mac"
                + (moves > 0 ? ", and a move deletes its source" : "")
                + ". Run it only if you wrote it or know who did."
        }
        if !skipped.isEmpty { detail += "\n\n\(skipped.count) lines will not be carried out." }
        detail += "\n\nYou are asked before a file that exists is replaced."
        return ("Run this download list? (\(counts.joined(separator: ", ")))", detail)
    }
}

/// One run through a download list. The copy jobs are asynchronous, so the run moves from
/// line to line in their completions. Main thread only; it keeps itself alive until the end.
@MainActor
private final class ListRun {
    private var items: ArraySlice<ListPlan.Item>
    private let kernel: Kernel
    private let transfers: any FileTransferService
    private var skipped: [String]
    /// A completion that comes back at once does not call into the next line from inside
    /// this one: with many lines that would be a call inside a call for each of them.
    private var isStepping = false
    private var stepsAgain = false

    init(plan: ListPlan, kernel: Kernel, transfers: any FileTransferService) {
        items = plan.items[...]
        skipped = plan.skipped
        self.kernel = kernel
        self.transfers = transfers
    }

    func next() {
        if isStepping {
            stepsAgain = true
            return
        }
        isStepping = true
        repeat {
            stepsAgain = false
            step()
        } while stepsAgain
        isStepping = false
    }

    private func step() {
        guard let item = items.popFirst() else {
            if !skipped.isEmpty {
                kernel.ui.inform(
                    "Some lines of the download list were not carried out.", detail: ListPlan.shortened(skipped),
                    style: .warning)
            }
            return
        }
        switch item {
        case .pause(let seconds):
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { self.next() }

        case .transfer(let step):
            let (from, to) = (step.from, step.to)
            let directory = to.deletingLastPathComponent()
            // The usual copy job, with its usual question when the name is taken in the folder.
            transfers.transfer(step.kind == .move ? .move : .copy, [from], into: directory, renamingSelfCopies: false) {
                [self] arrived in
                // The list may name the file differently at its destination.
                guard let arrived, arrived.lastPathComponent != to.lastPathComponent else { return next() }
                rename(arrived, to: to, replacing: false)
            }
        }
    }

    /// Gives the file that arrived the name the list wants. A file that has that name already
    /// is replaced only when the user says so; otherwise the new file keeps the name it came with.
    private func rename(_ arrived: URL, to: URL, replacing: Bool) {
        let fileSystems = kernel.fileSystems
        kernel.jobs.run(
            title: "Renaming:",
            work: { _ -> any Error? in
                do {
                    try fileSystems.provider(for: arrived).move(arrived, to: to, replacing: replacing)
                    return nil
                } catch {
                    return error
                }
            },
            completion: { [self] failure in
                if let failure, case FileSystemError.alreadyExists = failure, !replacing {
                    let question = "\(fileSystems.displayPath(to)) already exists."
                    let detail =
                        "The download list wants the file that arrived as \(arrived.lastPathComponent) to have this name. Replace the existing file?"
                    if kernel.ui.choose(question, detail: detail, buttons: ["Replace", "Keep Both"], style: .warning)
                        == 0
                    {
                        return rename(arrived, to: to, replacing: true)
                    }
                    skipped.append(
                        "\(fileSystems.displayPath(to)) exists and was kept; the new file is \(arrived.lastPathComponent)"
                    )
                } else if let failure {
                    skipped.append("\(fileSystems.displayPath(to)): \(failure.localizedDescription)")
                }
                kernel.panels.refresh([to.deletingLastPathComponent()], focus: failure == nil ? to : arrived)
                next()
            })
    }
}
