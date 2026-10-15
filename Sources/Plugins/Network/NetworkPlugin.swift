import AFMContracts
public import AFMKernel
import Foundation

/// The commands only this plugin uses (spec 11 › The Net menu, 17 › Command catalogue).
extension CommandID {
    public static let ftpNew: CommandID = "cm_FtpNew"
    public static let ftpDisconnect: CommandID = "cm_FtpDisconnect"
    public static let ftpHiddenFiles: CommandID = "cm_FtpHiddenFiles"
    public static let ftpSelectTransferMode: CommandID = "cm_FtpSelectTransferMode"
    public static let ftpAddToList: CommandID = "cm_FtpAddToList"
    public static let ftpDownloadList: CommandID = "cm_FtpDownloadList"
    /// `.text`: `session` or `session|/subdir`, the name of a saved connection (spec 11 ›
    /// Opening connections by command).
    public static let ftpOpen: CommandID = "FTPOPEN"
    /// Connect to Server: the Mac's form of *Network Connections…*. `.text`: the address.
    public static let netConnect: CommandID = "cm_NetConnect"
    /// Eject the volume the source panel shows: the Mac's form of *Disconnect Network Drives…*.
    public static let netDisconnect: CommandID = "cm_NetDisconnect"
}

/// The settings keys of the preference page.
enum NetworkSettings {
    static let passiveMode = "network.passiveMode"
    static let keepAlive = "network.keepAliveSeconds"
    static let transferMode = "network.transferMode"
    static let parallelConnections = "network.parallelConnections"
    static let textFiles = "network.textFiles"
    static let anonymousPassword = "network.anonymousPassword"
    static let timeout = "network.timeoutSeconds"
    static let askToSave = "network.askToSaveQuickConnections"
    static let listName = "network.downloadList"
    static let lastServer = "network.lastServerAddress"
    /// The plain FTP servers the user agreed to send a password to without encryption.
    static let unprotectedHosts = "network.unprotectedPasswordHosts"
    static let parallelChoices = ["1", "2", "3", "4", "6", "8"]

    /// Reads the preferences into the form the connections use. Main thread.
    static func values(from settings: any SettingsStore) -> NetworkOptions.Values {
        var values = NetworkOptions.Values()
        values.passiveByDefault = settings.flag(passiveMode, default: true)
        values.keepAliveInterval = max(0, TimeInterval(settings.text(keepAlive, default: "60")) ?? 60)
        values.transferMode = TransferMode(rawValue: settings.index(transferMode, default: 0)) ?? .binary
        let choice = settings.index(parallelConnections, default: 2)
        values.parallelConnections = parallelChoices.indices.contains(choice) ? Int(parallelChoices[choice]) ?? 3 : 3
        values.textFileMasks = settings.text(textFiles, default: NetworkOptions.defaultTextMasks)
        values.anonymousPassword = settings.text(anonymousPassword, default: NetworkOptions.defaultAnonymousPassword)
        values.timeout = min(600, max(3, TimeInterval(settings.text(timeout, default: "30")) ?? 30))
        return values
    }
}

/// The addresses the user typed in person (`ServerConsentService`): their servers count as
/// chosen. A location of another file system, or one that names no server, is ignored.
final class TypedAddresses: ServerConsentService {
    private let center: ConnectionCenter

    init(center: ConnectionCenter) {
        self.center = center
    }

    func userChose(_ location: URL) {
        guard let key = ServerKey(location), ServerKey.schemes.contains(key.scheme) else { return }
        center.noteChosen(key)
    }
}

/// FTP, FTP over TLS and SFTP servers as file systems, the connection dialogs, the download
/// list, and mounting network volumes (spec 11).
///
/// What is left out, and why: a master password (the passwords are in the macOS Keychain,
/// which is protected by the login); the PORT cable connection (obsolete); firewall and proxy
/// definitions, user-defined listing templates, server-to-server copies, MODE Z and client
/// certificates; sharing folders, which is Finder's business on a Mac (System Settings ›
/// Sharing).
public final class NetworkPlugin: Plugin {
    public let name = "Network"
    private let launchesApplications: Bool
    private let passwords: any PasswordStore?
    private let mounter: any VolumeMounter?
    private let sftpTransport: SFTPTransport?
    /// The live connections; tests look at them.
    public private(set) var center = ConnectionCenter()
    /// The behaviour behind the commands, once started.
    private(set) var commands: NetworkCommands?
    private var store: ConnectionStore?
    private var consent: TypedAddresses?

    /// The saved connections.
    public var connections: [SavedConnection] { store?.connections ?? [] }

    /// Tests turn `launchesApplications` off, so no volume is mounted through the system, and
    /// pass a password store of their own, so the Keychain is not touched. Without a store the
    /// Keychain is used when applications may be launched, and memory otherwise.
    public init(
        launchesApplications: Bool = true,
        passwords: any PasswordStore? = nil,
        mounter: any VolumeMounter? = nil,
        sftpTransport: SFTPTransport? = nil
    ) {
        self.launchesApplications = launchesApplications
        self.passwords = passwords
        self.mounter = mounter
        self.sftpTransport = sftpTransport
    }

    public func start(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        let passwords =
            self.passwords
            ?? (launchesApplications ? KeychainPasswords(service: kernel.productName + " network") : MemoryPasswords())
        // What the keys of this plugin are, for whoever exports the settings or takes them from a file.
        kernel.settingsKeys.declare(prefix: "network.")
        kernel.settingsKeys.declare("network.connections", kind: .connection)
        kernel.settingsKeys.declare("network.lastUsed", kind: .connection)
        kernel.settingsKeys.declare("network.history", kind: .history)
        kernel.settingsKeys.declare(NetworkSettings.lastServer, kind: .history)
        kernel.settingsKeys.declare(NetworkSettings.unprotectedHosts, kind: .trust)
        kernel.settingsKeys.declare("network.trustedCertificates", kind: .trust)
        let store = ConnectionStore(settings: kernel.settings, passwords: passwords)
        self.store = store
        let options = NetworkOptions()
        options.values = NetworkSettings.values(from: kernel.settings)
        // The certificates accepted for good come from the vault, on first use and off the main
        // thread; the ones an earlier version kept in the settings are not believed (see
        // `ConnectionStore.trustedCertificates`).
        let vault = store.vault
        let trust = CertificateTrust(load: { vault.trustedCertificates() })
        store.forgetTrustedCertificatesInSettings()
        let environment = SessionEnvironment(options: options, trust: trust)
        let center = ConnectionCenter(environment: environment)
        center.agentName = kernel.productName
        self.center = center
        let transport = sftpTransport
        center.makeSession = { profile, environment in
            switch profile.key.scheme {
            case "ftp", "ftps": return FTPSession(profile: profile, environment: environment)
            case "sftp": return SFTPSession(profile: profile, environment: environment, transport: transport)
            default: return nil
            }
        }
        center.storedPassword = { vault.password(for: $0) }
        center.setSaved(store.connections.map(\.profile))
        // The plugin keeps both; the questions of the center's sessions keep the store.
        store.onChange = { [weak store, weak center] in
            if let store, let center { center.setSaved(store.connections.map(\.profile)) }
        }
        for scheme in ServerKey.schemes {
            kernel.fileSystems.register(RemoteFileSystem(scheme: scheme, center: center))
        }
        // Whoever takes a location from the keyboard says so here, and the user is not asked
        // "Connect to X?" about an address typed a moment ago.
        let consent = TypedAddresses(center: center)
        self.consent = consent
        kernel.services.register((any ServerConsentService).self, consent)

        let mounter = self.mounter ?? (launchesApplications ? SystemVolumeMounter() : nil)
        let network = NetworkCommands(kernel: kernel, center: center, store: store, mounter: mounter)
        commands = network
        network.connectQuestions()
        register(network, in: kernel, center: center)

        kernel.preferences.add(
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
                onChange: { options.values = NetworkSettings.values(from: kernel.settings) }
            )
        )
    }

    private func register(_ network: NetworkCommands, in owner: Kernel, center: ConnectionCenter) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        let commands = kernel.commands
        let source = { kernel.panels.source.model }
        let sourceIsRemote = { ServerKey(source().directory) != nil }

        commands.register(
            Command(.ftpConnect, "FTP Connect…", [Shortcut(.character("f"), .control)]),
            network.showConnections
        )
        commands.register(
            Command(.ftpNew, "FTP New Connection…", [Shortcut(.character("n"), .control)]),
            network.quickConnect
        )
        commands.register(
            Command(.ftpDisconnect, "FTP Disconnect", [Shortcut(.character("f"), [.control, .shift])]),
            enabled: { !center.connected.isEmpty },
            network.disconnect
        )
        commands.register(
            Command(.ftpHiddenFiles, "FTP Show Hidden Files"),
            enabled: sourceIsRemote,
            checked: { source().showHidden },
            network.toggleHiddenFiles
        )
        commands.register(
            Command(
                .ftpSelectTransferMode,
                "FTP Transfer Mode…",
                [Shortcut(.character("m"), [.control, .shift])],
                runsDuringJobs: true
            ),
            network.selectTransferMode
        )
        commands.register(
            Command(.ftpAddToList, "FTP Add to Download List…"),
            enabled: { sourceIsRemote() && source().hasOperands },
            network.addToDownloadList
        )
        commands.register(Command(.ftpDownloadList, "FTP Download From List…"), network.downloadFromList)
        commands.register(
            Command(.ftpOpen, "Open Saved Connection"),
            parameterized: { argument in
                if let text = argument.text { network.open(saved: text) } else { network.showConnections() }
            }
        )
        commands.register(
            Command(.netConnect, "Connect to Server…", [.cmd("k")]),
            parameterized: { network.connectToServer($0.text) }
        )
        commands.register(
            Command(.netDisconnect, "Eject Volume"),
            enabled: { network.canEject && ServerSchemes.mountedVolume(of: source().directory) != nil },
            network.ejectVolume
        )

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

    /// Closes the connections when the program quits. Returns at once: nothing here waits for
    /// a server, the goodbyes are said in the background for as long as the program still runs.
    public func stop() {
        center.disconnectAll()
    }

    /// Waits until the passwords and certificates that were to be stored are stored; for tests.
    public func waitForStoredSecrets() {
        store?.vault.waitUntilDone()
    }
}
