import AFMKernel
import Foundation
import Security

/// Where the passwords of saved connections are kept. Safe from any thread.
public protocol PasswordStore: AnyObject {
    func password(for account: String) -> String?
    /// Nil removes the password.
    func setPassword(_ password: String?, for account: String)
}

/// Passwords in the user's login Keychain, as generic passwords under one service name
/// (spec 11 › Encrypt and the master password: the Keychain takes the place of both the
/// scrambled passwords in the settings file and the master password that protects them).
public final class KeychainPasswords: PasswordStore {
    /// The four calls of the Security framework this class makes; tests put a recording
    /// stand-in in their place, so the order of the calls is tested without a Keychain.
    struct Calls {
        var copy: (_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = {
            SecItemCopyMatching($0, $1)
        }
        var update: (_ query: CFDictionary, _ changes: CFDictionary) -> OSStatus = { SecItemUpdate($0, $1) }
        var add: (_ item: CFDictionary) -> OSStatus = { SecItemAdd($0, nil) }
        var delete: (_ query: CFDictionary) -> OSStatus = { SecItemDelete($0) }
    }

    private let service: String
    private let calls: Calls

    public convenience init(service: String) {
        self.init(service: service, calls: Calls())
    }

    init(service: String, calls: Calls) {
        self.service = service
        self.calls = calls
    }

    private func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    public func password(for account: String) -> String? {
        var query = query(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard calls.copy(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// The stored password is changed in place. It is only removed when that is what was
    /// asked for: removed first and added again, a failing second step would lose it.
    public func setPassword(_ password: String?, for account: String) {
        guard let password else {
            _ = calls.delete(query(account) as CFDictionary)
            return
        }
        let data = Data(password.utf8)
        let status = calls.update(query(account) as CFDictionary, [kSecValueData: data] as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var item = query(account)
        item[kSecValueData] = data
        item[kSecAttrLabel] = service
        _ = calls.add(item as CFDictionary)
    }
}

/// The secrets of the saved connections, kept in a `PasswordStore`, and the only way this plugin
/// reaches that store.
///
/// **A password belongs to a server and a login, not to an identifier.** It is kept under a
/// name made of the connection's identifier *and* its scheme, host, port and user name. The
/// settings, where the connections are listed, can be replaced by a file from somebody else;
/// a connection in such a file that carries a known identifier but another host has another
/// name here, and finds no password to send to that host. The certificates the user accepted
/// for good are kept here for the same reason, not in the settings.
///
/// **Threading.** Safe from any thread. The store may take a while (the Keychain can wait for
/// the user to unlock it), so nothing here is done on the calling thread unless the caller is
/// a connecting thread that needs the answer: changes are queued, in order, and reads wait
/// for the changes before them. The main thread only ever queues.
public final class PasswordVault {
    private let store: PasswordStore
    private let queue = DispatchQueue(label: "afm.network.keychain", qos: .userInitiated)
    private let lock = NSLock()
    /// The name the password of each saved connection is kept under, as the connections are now.
    private var accounts: [UUID: String] = [:]

    public static let trustedAccount = "trusted-certificates"
    /// Present once the passwords of an earlier version, kept by identifier alone, were moved.
    public static let boundAccount = "passwords-are-bound-to-servers"

    public init(store: PasswordStore) {
        self.store = store
    }

    /// The name the password of a connection is kept under.
    public static func account(of connection: SavedConnection) -> String {
        let key = connection.key
        let user = connection.anonymous ? "" : connection.user
        return "\(connection.id.uuidString) \(key.scheme)://\(user)@\(key.host):\(key.port)"
    }

    /// Tells which connections exist. Cheap; called on the main thread whenever the list changed.
    /// The first call also moves the passwords an earlier version kept by identifier alone, once.
    public func setConnections(_ connections: [SavedConnection]) {
        var current: [UUID: String] = [:]
        for connection in connections { current[connection.id] = Self.account(of: connection) }
        lock.lock()
        let isFirst = accounts.isEmpty
        accounts = current
        lock.unlock()
        guard isFirst, !current.isEmpty else { return }
        queue.async { [store] in
            guard store.password(for: Self.boundAccount) == nil else { return }
            for (id, account) in current {
                guard let old = store.password(for: id.uuidString) else { continue }
                if store.password(for: account) == nil { store.setPassword(old, for: account) }
                store.setPassword(nil, for: id.uuidString)
            }
            store.setPassword("1", for: Self.boundAccount)
        }
    }

    private func account(of id: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return accounts[id]
    }

    /// The stored password for a login that comes from a saved connection; nil when the
    /// connection is not known as it is now (its host or user is not the one the password was
    /// stored for). Waits for the store: for connecting threads, never the main thread.
    public func password(for profile: ConnectionProfile) -> String? {
        guard let id = profile.savedID, let account = account(of: id) else { return nil }
        return queue.sync { store.password(for: account) }
    }

    /// Stores, or with nil removes, the password of a connection. Returns at once.
    public func setPassword(_ password: String?, for connection: SavedConnection) {
        let account = Self.account(of: connection)
        queue.async { [store] in store.setPassword(password, for: account) }
    }

    /// Gives `connection` the password that `original` has: for a copy of a connection, and
    /// for a connection whose host or user the user changed in the dialog. With `removing`,
    /// the original's is removed afterwards. Returns at once.
    public func carryPassword(from original: SavedConnection, to connection: SavedConnection, removing: Bool) {
        let (from, to) = (Self.account(of: original), Self.account(of: connection))
        guard from != to else { return }
        queue.async { [store] in
            if let password = store.password(for: from) { store.setPassword(password, for: to) }
            if removing { store.setPassword(nil, for: from) }
        }
    }

    /// The certificates the user accepted for good, by host. Waits for the store.
    public func trustedCertificates() -> [String: [String]] {
        queue.sync { [store] in Self.decode(store.password(for: Self.trustedAccount)) }
    }

    /// Makes `fingerprints` the certificates accepted for good for `host`, in place of what was
    /// stored for it, or with `adding` in addition to it. Returns at once.
    public func setTrusted(_ fingerprints: [String], for host: String, adding: Bool) {
        let host = host.lowercased()
        queue.async { [store] in
            var all = Self.decode(store.password(for: Self.trustedAccount))
            let kept = adding ? (all[host] ?? []).filter { !fingerprints.contains($0) } : []
            all[host] = kept + fingerprints
            guard let data = try? JSONEncoder().encode(all) else { return }
            store.setPassword(String(decoding: data, as: UTF8.self), for: Self.trustedAccount)
        }
    }

    /// Whether a certificate is stored for good for `host`. Waits for the store.
    public func hasTrusted(for host: String) -> Bool {
        !(trustedCertificates()[host.lowercased()] ?? []).isEmpty
    }

    private static func decode(_ text: String?) -> [String: [String]] {
        guard let text, let all = try? JSONDecoder().decode([String: [String]].self, from: Data(text.utf8)) else {
            return [:]
        }
        return all
    }

    /// Waits until everything that was queued is done; for tests.
    public func waitUntilDone() {
        queue.sync {}
    }
}

/// Passwords that live as long as the program; for tests, which never touch the Keychain.
public final class MemoryPasswords: PasswordStore {
    private let lock = NSLock()
    private var passwords: [String: String] = [:]

    public init() {}

    public func password(for account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return passwords[account]
    }

    public func setPassword(_ password: String?, for account: String) {
        lock.lock()
        defer { lock.unlock() }
        passwords[account] = password
    }

    public var accounts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return passwords.keys.sorted()
    }
}

/// A connection the user saved (spec 11 › "FTP: connection details" dialog). The password is
/// not part of it: it is kept in the Keychain under the connection's `id`.
public struct SavedConnection: Codable, Equatable {
    /// The protocols in the order the dialog offers them.
    public enum Kind: Int, Codable, CaseIterable {
        case ftp, ftpExplicitTLS, ftpImplicitTLS, sftp

        public var title: String {
            switch self {
            case .ftp: return "FTP"
            case .ftpExplicitTLS: return "FTP over TLS (explicit, AUTH TLS)"
            case .ftpImplicitTLS: return "FTP over TLS (implicit)"
            case .sftp: return "SFTP (secure shell)"
            }
        }

        public var scheme: String {
            switch self {
            case .ftp: return "ftp"
            case .ftpExplicitTLS, .ftpImplicitTLS: return "ftps"
            case .sftp: return "sftp"
            }
        }

        public var tls: TLSMode {
            switch self {
            case .ftpExplicitTLS: return .explicit
            case .ftpImplicitTLS: return .implicit
            default: return .none
            }
        }

        public var defaultPort: Int {
            switch self {
            case .ftpImplicitTLS: return 990
            case .sftp: return 22
            default: return 21
            }
        }

        public init(scheme: String, tls: TLSMode) {
            self =
                scheme == "sftp"
                ? .sftp : tls == .implicit ? .ftpImplicitTLS : tls == .explicit ? .ftpExplicitTLS : .ftp
        }
    }

    /// How directories are listed (spec 11 › Listing: MLSD or LIST).
    public enum Listing: Int, Codable, CaseIterable {
        case automatic, mlsd, list

        public var title: String {
            switch self {
            case .automatic: return "Auto-detect (MLSD if offered)"
            case .mlsd: return "Always MLSD"
            case .list: return "Always LIST"
            }
        }
    }

    public var id = UUID()
    public var name = ""
    public var kind = Kind.ftp
    public var host = ""
    /// Nil is the protocol's usual port.
    public var port: Int?
    public var user = ""
    public var anonymous = false
    public var remoteDirectory = ""
    public var localDirectory = ""
    public var passive = true
    public var encoding = NameEncoding.automatic
    public var listing = Listing.automatic
    /// Commands sent after the login, separated by `;`.
    public var initCommands = ""

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, host, port, user, anonymous, remoteDirectory, localDirectory, passive, encoding, listing,
            initCommands
    }

    /// Reads a connection from the settings, which a damaged or foreign file may have filled
    /// with anything: a member that is missing or of the wrong kind takes its usual value, and
    /// a port that is none (`-2`, `70000`) is the usual port. Only the identifier must be there.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func read<Value: Decodable>(_ key: CodingKeys, _ fallback: Value) -> Value {
            (try? values.decodeIfPresent(Value.self, forKey: key)) ?? fallback
        }
        id = try values.decode(UUID.self, forKey: .id)
        name = read(.name, "")
        kind = read(.kind, Kind.ftp)
        host = read(.host, "")
        port = (try? values.decodeIfPresent(Int.self, forKey: .port)).flatMap {
            ServerKey.validPorts.contains($0) ? $0 : nil
        }
        user = read(.user, "")
        anonymous = read(.anonymous, false)
        remoteDirectory = read(.remoteDirectory, "")
        localDirectory = read(.localDirectory, "")
        passive = read(.passive, true)
        encoding = read(.encoding, NameEncoding.automatic)
        listing = read(.listing, Listing.automatic)
        initCommands = read(.initCommands, "")
    }

    public var key: ServerKey { ServerKey(scheme: kind.scheme, host: host, port: port ?? kind.defaultPort) }

    /// `host` or `host:port`, as the dialog shows it.
    public var hostText: String {
        let bare = host.contains(":") ? "[\(host)]" : host
        return port.map { "\(bare):\($0)" } ?? bare
    }

    /// The row in the list of connections.
    public var listTitle: String { "\(name)  —  \(key.description)" }

    public var profile: ConnectionProfile {
        ConnectionProfile(
            key: key, name: name.isEmpty ? nil : name, savedID: id, tls: kind.tls,
            user: anonymous || user.isEmpty ? nil : user,
            anonymous: anonymous, passive: passive, encoding: encoding,
            remoteDirectory: remoteDirectory.isEmpty ? nil : RemotePath.normalized(remoteDirectory),
            initCommands: FTPServerConfig.initCommands(from: initCommands),
            usesMLSD: listing == .automatic ? nil : listing == .mlsd)
    }

    /// Fills host, port, protocol and user from what was typed into the host field, which may
    /// be a plain name, `host:port`, or a whole address with a scheme. False when it is none of these.
    public mutating func setHost(_ text: String, kind chosen: Kind) -> Bool {
        guard let address = ServerAddress(text, defaultScheme: chosen.scheme) else { return false }
        let hasScheme = text.contains("://")
        kind = hasScheme ? Kind(scheme: address.scheme, tls: address.tls) : chosen
        host = address.host
        let typedPort = address.port
        // A port is only stored when it is not the one the protocol uses anyway.
        let typed = text.range(of: ":\(typedPort)") != nil
        port = typed && typedPort != kind.defaultPort ? typedPort : nil
        if let user = address.user { (self.user, anonymous) = (user, false) }
        if address.hasPath, remoteDirectory.isEmpty { remoteDirectory = address.path }
        return true
    }
}

/// The saved connections and what else the connection dialogs remember, in the plugin's corner
/// of the settings (`network.`). Passwords go to the `PasswordStore`. Main thread only.
public final class ConnectionStore {
    private let settings: SettingsStore
    public let passwords: PasswordStore
    /// The passwords and accepted certificates, by server; everything goes through it.
    public let vault: PasswordVault
    /// Called after the list changed.
    public var onChange: () -> Void = {}

    private static let connectionsKey = "connections"
    private static let lastUsedKey = "lastUsed"
    private static let historyKey = "history"
    private static let historyLimit = 12

    public init(settings: SettingsStore, passwords: PasswordStore) {
        self.settings = settings.scoped(to: "network")
        self.passwords = passwords
        vault = PasswordVault(store: passwords)
        vault.setConnections(connections)
    }

    public var connections: [SavedConnection] {
        get { settings.value([SavedConnection].self, forKey: Self.connectionsKey) ?? [] }
        set {
            settings.set(newValue, forKey: Self.connectionsKey)
            vault.setConnections(newValue)
            onChange()
        }
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

    public func connection(named name: String) -> SavedConnection? {
        connections.first { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    /// The connection the list starts on (spec 11 › The list).
    public var lastUsed: UUID? {
        get { settings.value(UUID.self, forKey: Self.lastUsedKey) }
        set { settings.set(newValue, forKey: Self.lastUsedKey) }
    }

    /// The addresses of quick connections, newest first. They never contain a password.
    public var history: [String] {
        settings.value([String].self, forKey: Self.historyKey) ?? []
    }

    public func remember(address: ServerAddress) {
        let text = address.textWithoutPassword
        settings.set(
            Array(([text] + history.filter { $0 != text }).prefix(Self.historyLimit)),
            forKey: Self.historyKey)
    }

    /// What an earlier version kept in the settings: certificates to always trust, by host.
    /// **Nothing trusts these any more.** The settings can be replaced by a file from somebody
    /// else, and a fingerprint planted there would make a forged certificate pass without a
    /// question. The certificates the user accepts for good are kept by `vault`; what stands
    /// here is ignored and removed (`forgetTrustedCertificatesInSettings`), so each server
    /// asks once more.
    public var trustedCertificates: [String: [String]] {
        get { settings.value([String: [String]].self, forKey: "trustedCertificates") ?? [:] }
        set { settings.set(newValue, forKey: "trustedCertificates") }
    }

    public func forgetTrustedCertificatesInSettings() {
        if !trustedCertificates.isEmpty { trustedCertificates = [:] }
    }
}
