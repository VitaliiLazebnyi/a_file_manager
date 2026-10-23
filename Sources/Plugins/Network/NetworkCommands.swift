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
internal final class NetworkCommands {
    /// Unowned: the kernel owns the plugin, and through it this.
    internal unowned let kernel: Kernel
    /// The live connections.
    internal let center: ConnectionCenter
    /// The saved connections and what the dialogs remember.
    internal let store: ConnectionStore
    /// Mounts and ejects network volumes; nil where nothing is mounted (tests).
    internal let mounter: (any VolumeMounter)?
    /// Where each panel was before it showed a server, to return there on Disconnect.
    internal var lastLocal: [ObjectIdentifier: URL] = [:]
    /// Keeps the subscription to the panels' events, which fills `lastLocal`.
    private var panelSubscription: AnyObject?

    /// How the user is asked and told.
    internal var interaction: any UserInteraction { kernel.interaction }
    /// The source panel.
    internal var source: any PanelHandle { kernel.panels.source }
    /// Whether Eject Volume can be offered: only with a mounter.
    internal var canEject: Bool { mounter != nil }

    /// The commands of the Net menu, which connect through `center`, remember in `store` and mount with `mounter`.
    internal init(kernel: Kernel, center: ConnectionCenter, store: ConnectionStore, mounter: (any VolumeMounter)?) {
        self.kernel = kernel
        self.center = center
        self.store = store
        self.mounter = mounter
        panelSubscription = kernel.panelEvents.subscribe { [weak self] event, panel in
            guard case .locationChanged = event, panel.model.directory.isFileURL else {
                return
            }
            self?.lastLocal[ObjectIdentifier(panel)] = panel.model.directory
        }
    }

    /// The text of a list file.
    ///
    /// A list is a small text; a file that is no plain file, or larger than
    /// `DownloadList.largestFile`, is not read.
    nonisolated internal static func readList(_ list: URL) throws -> String {
        let values = try list.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw VolumeError(message: "\(list.path) is not a file.") }
        let limit = DownloadList.largestFile
        // No more than one byte beyond the limit is read: enough to tell a list that is too large.
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

    // MARK: Connecting

    /// Opens the connection in the source panel (spec 11 › Connecting), in `path` or where the login leads.
    ///
    /// The login runs as a job with a Cancel button; the panel follows when it succeeded, and the
    /// other panel goes to `localDirectory` when one is given. `saved` becomes the connection the list
    /// starts on.
    internal func connect(
        _ profile: ConnectionProfile,
        path: String?,
        localDirectory: String?,
        saved: SavedConnection?
    ) {
        let (servers, key, panel) = (center, profile.key, source)
        if panel.model.directory.isFileURL { lastLocal[ObjectIdentifier(panel)] = panel.model.directory }
        // The user asked for this connection; no question whether to connect at all.
        if !servers.isConnected(key) { servers.announce(profile, chosen: true) }
        kernel.jobs.run(
            title: "Connect to \(profile.title)",
            work: { monitor -> Result<String, any Error> in
                monitor.report(
                    JobProgress(
                        lines: [
                            "Connect to: \(key.description)",
                            "User name: \(profile.user ?? (profile.anonymous ? "anonymous" : ""))"
                        ],
                        itemsDone: 0,
                        itemsTotal: 0
                    )
                )
                return Result { try servers.connect(key, cancellation: monitor.cancellation) }
            },
            completion: { [kernel, store] result in
                switch result {
                case .success(let home):
                    if let saved { store.lastUsed = saved.id }
                    panel.show(key.url(path: path ?? profile.remoteDirectory ?? home))
                    // The other panel goes to the local folder that belongs to the connection.
                    if let localDirectory, !localDirectory.isEmpty {
                        let other = panel === kernel.panels.left ? kernel.panels.right : kernel.panels.left
                        other.show(URL(fileURLWithPath: localDirectory.expandingTilde, isDirectory: true))
                    }

                case .failure(let error):
                    // Returns at once: what waits for the server is done in the background.
                    servers.disconnect(key)
                    if case NetworkError.cancelled = error {
                        return
                    }
                    kernel.interaction.report(error, title: "Connect failed!")
                }
            }
        )
    }

    /// `FTPOPEN session` and `FTPOPEN session|/subdir`.
    internal func open(saved text: String) {
        let parts = text.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let name = parts.first, let connection = store.connection(named: name) else {
            interaction.inform("There is no saved connection named \(text).", detail: "", style: .warning)
            return
        }
        // `|*/dir` asks for the active panel, which is where connections open anyway.
        let path = parts.count > 1 ? String(parts[1].drop { $0 == "*" }) : nil
        connect(connection.profile, path: path, localDirectory: connection.localDirectory, saved: connection)
    }

    /// Ctrl+N: quick connect by host or URL (spec 11 › Quick connect).
    internal func quickConnect() {
        let history = store.history
        var fields: [FormField] = [.text("address", "Connect to (host or URL):", history.first ?? "")]
        if history.count > 1 { fields.append(.choice("recent", "Recent:", ["—"] + history)) }
        fields.append(.checkbox("anonymous", "Anonymous connection", true))
        guard
            let answer = interaction.form(
                "FTP: new connection",
                detail: "host, host:port, user@host or ftp://, ftps://, ftpes://, ftpis://, sftp://…",
                fields: fields,
                buttons: ["OK"]
            )
        else { return }
        let recent = answer.index("recent")
        let text = recent > 0 && history.indices.contains(recent - 1) ? history[recent - 1] : answer.text("address")
        guard let address = ServerAddress(text) else {
            // What was typed may hold a password; it is not shown again.
            interaction.inform(
                "\(ServerAddress.removingPassword(from: text)) is not a server address.",
                detail: "",
                style: .warning
            )
            return
        }
        store.remember(address: address)
        // A user name in the address means: not as a guest.
        let anonymous = answer.flag("anonymous") && address.user == nil && address.scheme != "sftp"
        let user = address.user ?? (address.scheme == "sftp" ? NSUserName() : nil)
        connect(
            ConnectionProfile(
                key: address.key,
                tls: address.tls,
                user: user,
                password: address.password,
                anonymous: anonymous
            ),
            path: address.hasPath ? address.path : nil,
            localDirectory: nil,
            saved: nil
        )
    }

    // MARK: Options of the session

    /// FTP Show Hidden Files: the panels' own Show Hidden command when there is one, else the source panel's setting.
    internal func toggleHiddenFiles() {
        if kernel.commands[.showHidden] != nil {
            kernel.commands.perform(.showHidden)
        } else {
            source.model.setShowHidden(!source.model.showHidden)
            source.reload()
        }
    }

    /// Ctrl+Shift+M (spec 11 › Transfer modes).
    internal func selectTransferMode() {
        let current = kernel.settings.index(NetworkSettings.transferMode, default: 0)
        guard
            let answer = interaction.form(
                "FTP transfer mode",
                detail: "Text mode converts line ends; binary transfers files unchanged.",
                fields: [.choice("mode", "Transfer mode:", TransferMode.allCases.map(\.title), selected: current)],
                buttons: ["OK"]
            )
        else { return }
        kernel.settings.set(answer.index("mode"), forKey: NetworkSettings.transferMode)
        center.environment.options.values = NetworkSettings.values(from: kernel.settings)
    }

    deinit {
        // Nothing to release.
    }
}
