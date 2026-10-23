public import AFMKernel
public import Foundation

/// The saved connections and what else the connection dialogs remember, in the plugin's corner
/// of the settings (`network.`).
///
/// Passwords go to the `PasswordStore`. Main thread only.
@preconcurrency
@MainActor
public final class ConnectionStore {
    /// The key of the saved connections in the plugin's settings.
    private static let connectionsKey = "connections"
    /// The key of the identifier of the connection last used.
    private static let lastUsedKey = "lastUsed"
    /// The key of the addresses of quick connections.
    private static let historyKey = "history"
    /// How many addresses of quick connections are remembered.
    private static let historyLimit = 12

    /// The settings, scoped to `network.`.
    private let settings: any SettingsStore
    /// Where the passwords are kept; read and written through `vault` only.
    public let passwords: any PasswordStore
    /// The passwords and accepted certificates, by server; everything goes through it.
    public let vault: PasswordVault
    /// Called after the list changed.
    public var onChange: () -> Void = {
        // Nobody is told until the plugin says whom.
    }

    /// The saved connections, in the order of the list; setting them stores them and tells `vault` and `onChange`.
    public var connections: [SavedConnection] {
        get { settings.value([SavedConnection].self, forKey: Self.connectionsKey) ?? [] }
        set {
            settings.set(newValue, forKey: Self.connectionsKey)
            vault.setConnections(newValue)
            onChange()
        }
    }

    /// The connection the list starts on (spec 11 › The list).
    public var lastUsed: UUID? {
        get { settings.value(UUID.self, forKey: Self.lastUsedKey) }
        set { settings.set(newValue, forKey: Self.lastUsedKey) }
    }

    /// The addresses of quick connections, newest first.
    ///
    /// They never contain a password.
    public var history: [String] {
        settings.value([String].self, forKey: Self.historyKey) ?? []
    }

    /// What an earlier version kept in the settings: certificates to always trust, by host.
    ///
    /// **Nothing trusts these any more.** The settings can be replaced by a file from somebody
    /// else, and a fingerprint planted there would make a forged certificate pass without a
    /// question. The certificates the user accepts for good are kept by `vault`; what stands here
    /// is ignored and removed (`forgetTrustedCertificatesInSettings`), so each server asks once
    /// more.
    public var trustedCertificates: [String: [String]] {
        get { settings.value([String: [String]].self, forKey: "trustedCertificates") ?? [:] }
        set { settings.set(newValue, forKey: "trustedCertificates") }
    }

    /// A store in the `network` corner of `settings` whose passwords go to `passwords`.
    public init(settings: any SettingsStore, passwords: any PasswordStore) {
        self.settings = settings.scoped(to: "network")
        self.passwords = passwords
        vault = PasswordVault(store: passwords)
        vault.setConnections(connections)
    }

    /// Adds the connection, or replaces the one with the same id.
    public func save(_ connection: SavedConnection) {
        var all = connections
        if let index = all.firstIndex(where: { $0.id == connection.id }) {
            all[index] = connection
        } else {
            all.append(connection)
        }
        connections = all
    }

    /// Removes the connection and its password.
    public func delete(_ connection: SavedConnection) {
        vault.setPassword(nil, for: connection)
        connections = connections.filter { $0.id != connection.id }
    }

    /// The saved connection called `name`, ignoring case; nil when there is none.
    public func connection(named name: String) -> SavedConnection? {
        connections.first { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    /// Puts the address of a quick connection first in `history`, without its password.
    public func remember(address: ServerAddress) {
        let text = address.textWithoutPassword
        settings.set(
            Array(([text] + history.filter { $0 != text }).prefix(Self.historyLimit)),
            forKey: Self.historyKey
        )
    }

    /// Removes the certificates an earlier version kept in the settings (see `trustedCertificates`).
    public func forgetTrustedCertificatesInSettings() {
        if !trustedCertificates.isEmpty { trustedCertificates = [:] }
    }

    deinit {
        // Nothing to release.
    }
}
