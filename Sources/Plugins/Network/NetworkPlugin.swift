import AFMContracts
public import AFMKernel

/// FTP, FTP over TLS and SFTP servers as file systems, the connection dialogs, the download
/// list, and mounting network volumes (spec 11).
///
/// What is left out, and why: a master password (the passwords are in the macOS Keychain,
/// which is protected by the login); the PORT cable connection (obsolete); firewall and proxy
/// definitions, user-defined listing templates, server-to-server copies, MODE Z and client
/// certificates; sharing folders, which is Finder's business on a Mac (System Settings ›
/// Sharing).
public final class NetworkPlugin: Plugin {
    /// The plugin's name in the list of plugins.
    public let name = "Network"
    /// False in tests: no volume is mounted through the system and the Keychain is not used.
    private let launchesApplications: Bool
    /// The password store given to `init`; nil to pick one in `start(in:)`.
    private let passwords: (any PasswordStore)?
    /// The mounter given to `init`; nil for the system's when applications may be launched.
    private let mounter: (any VolumeMounter)?
    /// How SFTP sessions reach their server; nil for the `ssh` program.
    private let sftpTransport: SFTPTransport?
    /// The live connections; tests look at them.
    public private(set) var center = ConnectionCenter()
    /// The behaviour behind the commands, once started.
    internal private(set) var commands: NetworkCommands?
    /// The saved connections and their passwords, once started.
    private var store: ConnectionStore?
    /// The service that tells the center which addresses the user typed, once started.
    private var consent: TypedAddresses?

    /// The saved connections.
    public var connections: [SavedConnection] { store?.connections ?? [] }

    /// Tests turn `launchesApplications` off, so no volume is mounted through the system, and
    /// pass a password store of their own, so the Keychain is not touched.
    ///
    /// Without a store the Keychain is used when applications may be launched, and memory
    /// otherwise.
    public init(
        launchesApplications: Bool = true,
        passwords: (any PasswordStore)? = nil,
        mounter: (any VolumeMounter)? = nil,
        sftpTransport: SFTPTransport? = nil
    ) {
        self.launchesApplications = launchesApplications
        self.passwords = passwords
        self.mounter = mounter
        self.sftpTransport = sftpTransport
    }

    /// The keys of this plugin, for whoever exports the settings or takes them from a file.
    private static func declareSettingsKeys(in keys: SettingsKeyRegistry) {
        keys.declare(prefix: "network.")
        keys.declare("network.connections", kind: .connection)
        keys.declare("network.lastUsed", kind: .connection)
        keys.declare("network.history", kind: .history)
        keys.declare(NetworkSettings.lastServer, kind: .history)
        keys.declare(NetworkSettings.unprotectedHosts, kind: .trust)
        keys.declare("network.trustedCertificates", kind: .trust)
    }

    /// The preference page; `onChange` is run on the main thread after the user changed one of its settings.
    private static func preferencePage(onChange: @escaping @MainActor @Sendable () -> Void) -> PreferencePage {
        PreferencePage(
            title: "FTP and Network",
            preferences: [
                Preference(
                    NetworkSettings.passiveMode,
                    "Use passive mode by default (like a web browser)",
                    .flag(default: true)
                ),
                Preference(
                    NetworkSettings.transferMode,
                    "Default transfer mode",
                    .choice(TransferMode.allCases.map(\.title), default: 0)
                ),
                Preference(
                    NetworkSettings.textFiles,
                    "Text files in automatic mode",
                    .text(default: NetworkOptions.defaultTextMasks)
                ),
                Preference(
                    NetworkSettings.parallelConnections,
                    "Connections per server used at the same time",
                    .choice(NetworkSettings.parallelChoices, default: 2)
                ),
                Preference(
                    NetworkSettings.keepAlive,
                    "Keep idle connections alive every … seconds (0 = off)",
                    .text(default: "60")
                ),
                Preference(NetworkSettings.timeout, "Seconds to wait for a server's answer", .text(default: "30")),
                Preference(
                    NetworkSettings.anonymousPassword,
                    "E-mail address as password for anonymous logins",
                    .text(default: NetworkOptions.defaultAnonymousPassword)
                ),
                Preference(
                    NetworkSettings.askToSave,
                    "Offer to save a quick connection when disconnecting",
                    .flag(default: true)
                )
            ],
            onChange: onChange
        )
    }

    /// Registers the commands of the plugin; `source` gives the source panel's model, on the main thread.
    private static func register(
        _ network: NetworkCommands,
        in registry: CommandRegistry,
        source: @escaping () -> PanelModel,
        center: ConnectionCenter
    ) {
        let sourceIsRemote = { ServerKey(source().directory) != nil }
        registry.register(
            Command(.ftpConnect, "FTP Connect…", [Shortcut(.character("f"), .control)]),
            network.showConnections
        )
        registry.register(
            Command(.ftpNew, "FTP New Connection…", [Shortcut(.character("n"), .control)]),
            network.quickConnect
        )
        registry.register(
            Command(.ftpDisconnect, "FTP Disconnect", [Shortcut(.character("f"), [.control, .shift])]),
            enabled: { !center.connected.isEmpty },
            network.disconnect
        )
        registry.register(
            Command(.ftpHiddenFiles, "FTP Show Hidden Files"),
            enabled: sourceIsRemote,
            checked: { source().showHidden },
            network.toggleHiddenFiles
        )
        registry.register(
            Command(
                .ftpSelectTransferMode,
                "FTP Transfer Mode…",
                [Shortcut(.character("m"), [.control, .shift])],
                runsDuringJobs: true
            ),
            network.selectTransferMode
        )
        registry.register(
            Command(.ftpAddToList, "FTP Add to Download List…"),
            enabled: { sourceIsRemote() && source().hasOperands },
            network.addToDownloadList
        )
        registry.register(Command(.ftpDownloadList, "FTP Download From List…"), network.downloadFromList)
        registry.register(Command(.ftpOpen, "Open Saved Connection")) { (argument: CommandArgument) in
            if let text = argument.text { network.open(saved: text) } else { network.showConnections() }
        }
        registry.register(Command(.netConnect, "Connect to Server…", [.cmd("k")])) { (argument: CommandArgument) in
            network.connectToServer(argument.text)
        }
        registry.register(
            Command(.netDisconnect, "Eject Volume"),
            enabled: { network.canEject && ServerSchemes.mountedVolume(of: source().directory) != nil },
            network.ejectVolume
        )
    }

    /// Puts the commands into the Net menu and onto the button bar of `kernel`.
    private static func addMenusAndButtons(to kernel: Kernel) {
        kernel.menus.add([.ftpConnect, .ftpNew, .ftpDisconnect, .ftpHiddenFiles], to: .netConnections)
        kernel.menus.add([.ftpSelectTransferMode, .ftpAddToList, .ftpDownloadList], to: .netTransfers)
        kernel.menus.add([.netConnect, .netDisconnect], to: .netVolumes)
        kernel.toolbar.add(
            .ftpConnect,
            symbol: "network",
            group: 70,
            hint: "Connect to an FTP or SFTP server from your saved connections."
        )
        kernel.toolbar.add(
            .ftpNew,
            symbol: "link",
            group: 70,
            hint: "Connect to an FTP or SFTP server by typing its address."
        )
        kernel.toolbar.add(
            .ftpDisconnect,
            symbol: "bolt.horizontal.circle",
            group: 70,
            hint: "Close the connection to an FTP or SFTP server."
        )
        kernel.toolbar.add(
            .netConnect,
            symbol: "server.rack",
            group: 70,
            hint: "Connect to a network share (SMB and others); it appears as a drive."
        )
        kernel.toolbar.setSymbol("eject", for: .netDisconnect)
        kernel.toolbar.setSymbol("arrow.down.doc", for: .ftpDownloadList)
        kernel.toolbar.setSymbol("text.badge.plus", for: .ftpAddToList)
        kernel.toolbar.setSymbol("eye", for: .ftpHiddenFiles)
        kernel.toolbar.setSymbol("arrow.left.arrow.right", for: .ftpSelectTransferMode)
    }

    /// Sets up the connections, file systems, commands, menus, toolbar buttons and the preference page in `owner`.
    ///
    /// Main thread, once, when the kernel starts its plugins.
    public func start(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        let secrets =
            passwords
            ?? (launchesApplications ? KeychainPasswords(service: kernel.productName + " network") : MemoryPasswords())
        Self.declareSettingsKeys(in: kernel.settingsKeys)
        let connectionStore = ConnectionStore(settings: kernel.settings, passwords: secrets)
        store = connectionStore
        let options = NetworkOptions()
        options.values = NetworkSettings.values(from: kernel.settings)
        let liveCenter = makeCenter(store: connectionStore, options: options, agentName: kernel.productName)
        center = liveCenter
        for scheme in ServerKey.schemes {
            kernel.fileSystems.register(RemoteFileSystem(scheme: scheme, center: liveCenter))
        }
        // Whoever takes a location from the keyboard says so here, and the user is not asked
        // "Connect to X?" about an address typed a moment ago.
        let typed = TypedAddresses(center: liveCenter)
        consent = typed
        kernel.services.register((any ServerConsentService).self, typed)

        let volumes = mounter ?? (launchesApplications ? SystemVolumeMounter() : nil)
        let network = NetworkCommands(kernel: kernel, center: liveCenter, store: connectionStore, mounter: volumes)
        commands = network
        network.connectQuestions()
        Self.register(network, in: kernel.commands, source: { kernel.panels.source.model }, center: liveCenter)
        Self.addMenusAndButtons(to: kernel)
        kernel.preferences.add(Self.preferencePage { options.values = NetworkSettings.values(from: kernel.settings) })
    }

    /// The center of the connections, which makes their sessions and knows the saved ones and the trusted
    /// certificates of `connectionStore`.
    private func makeCenter(
        store connectionStore: ConnectionStore,
        options: NetworkOptions,
        agentName: String
    ) -> ConnectionCenter {
        // The certificates accepted for good come from the vault, on first use and off the main
        // thread; the ones an earlier version kept in the settings are not believed (see
        // `ConnectionStore.trustedCertificates`).
        let vault = connectionStore.vault
        let trust = CertificateTrust { vault.trustedCertificates() }
        connectionStore.forgetTrustedCertificatesInSettings()
        let made = ConnectionCenter(environment: SessionEnvironment(options: options, trust: trust))
        made.agentName = agentName
        let transport = sftpTransport
        made.makeSession = { profile, environment in
            switch profile.key.scheme {
            case "ftp", "ftps":
                return FTPSession(profile: profile, environment: environment)

            case "sftp":
                return SFTPSession(profile: profile, environment: environment, transport: transport)

            default:
                return nil
            }
        }
        made.storedPassword = { vault.password(for: $0) }
        made.setSaved(connectionStore.connections.map(\.profile))
        // The plugin keeps both; the questions of the center's sessions keep the store.
        connectionStore.onChange = { [weak connectionStore, weak made] in
            if let connectionStore, let made { made.setSaved(connectionStore.connections.map(\.profile)) }
        }
        return made
    }

    /// Closes the connections when the program quits.
    ///
    /// Returns at once: nothing here waits for a server, the goodbyes are said in the background
    /// for as long as the program still runs.
    public func stop() {
        center.disconnectAll()
    }

    /// Waits until the passwords and certificates that were to be stored are stored; for tests.
    public func waitForStoredSecrets() {
        store?.vault.waitUntilDone()
    }

    deinit {
        // Nothing to release.
    }
}
