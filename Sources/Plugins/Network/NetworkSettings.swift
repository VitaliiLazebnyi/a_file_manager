import AFMKernel
import Foundation

/// The settings keys of the preference page.
internal enum NetworkSettings {
    /// Whether connections use passive mode unless a saved connection says otherwise (a flag).
    internal static let passiveMode = "network.passiveMode"
    /// Seconds between the keep-alive commands sent to an idle connection, 0 for none (text).
    internal static let keepAlive = "network.keepAliveSeconds"
    /// The default transfer mode, an index into `TransferMode.allCases`.
    internal static let transferMode = "network.transferMode"
    /// How many connections per server work at once, an index into `parallelCounts`.
    internal static let parallelConnections = "network.parallelConnections"
    /// The masks of the files sent as text in automatic mode.
    internal static let textFiles = "network.textFiles"
    /// The password given for anonymous logins, by custom an e-mail address.
    internal static let anonymousPassword = "network.anonymousPassword"
    /// Seconds to wait for a server's answer (text, 3 to 600).
    internal static let timeout = "network.timeoutSeconds"
    /// Whether disconnecting from a quick connection offers to save it (a flag).
    internal static let askToSave = "network.askToSaveQuickConnections"
    /// The path of the download list last named, proposed the next time one is asked for.
    internal static let listName = "network.downloadList"
    /// The address last given to Connect to Server, without its password.
    internal static let lastServer = "network.lastServerAddress"
    /// The plain FTP servers the user agreed to send a password to without encryption.
    internal static let unprotectedHosts = "network.unprotectedPasswordHosts"
    /// The numbers of parallel connections the preference offers, in menu order.
    internal static let parallelCounts = [1, 2, 3, 4, 6, 8]
    /// `parallelCounts` as the menu shows them.
    internal static let parallelChoices = parallelCounts.map(String.init)

    /// Reads the preferences into the form the connections use.
    ///
    /// Main thread.
    internal static func values(from settings: any SettingsStore) -> NetworkOptions.Values {
        var values = NetworkOptions.Values()
        values.passiveByDefault = settings.flag(passiveMode, default: true)
        values.keepAliveInterval = max(0, TimeInterval(settings.text(keepAlive, default: "60")) ?? 60)
        values.transferMode = TransferMode(rawValue: settings.index(transferMode, default: 0)) ?? .binary
        let choice = settings.index(parallelConnections, default: 2)
        values.parallelConnections = parallelCounts.indices.contains(choice) ? parallelCounts[choice] : 3
        values.textFileMasks = settings.text(textFiles, default: NetworkOptions.defaultTextMasks)
        values.anonymousPassword = settings.text(anonymousPassword, default: NetworkOptions.defaultAnonymousPassword)
        values.timeout = min(600, max(3, TimeInterval(settings.text(timeout, default: "30")) ?? 30))
        return values
    }
}
