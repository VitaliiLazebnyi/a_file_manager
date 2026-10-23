import Foundation

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
///
/// `accounts` is guarded by `lock`; the store is used on `queue`.
public final class PasswordVault: @unchecked Sendable {
    /// The account the accepted certificates are kept under, as JSON: fingerprints by host.
    public static let trustedAccount = "trusted-certificates"
    /// Present once the passwords of an earlier version, kept by identifier alone, were moved.
    public static let boundAccount = "passwords-are-bound-to-servers"

    /// Where the secrets are kept; used on `queue` only.
    private let store: any PasswordStore
    /// Runs the store's calls one after the other, in the order they were asked for.
    private let queue = DispatchQueue(label: "afm.network.keychain", qos: .userInitiated)
    /// Guards `accounts`.
    private let lock = NSLock()
    /// The name the password of each saved connection is kept under, as the connections are now.
    private var accounts: [UUID: String] = [:]

    /// A vault that keeps its secrets in `store`.
    public init(store: any PasswordStore) {
        self.store = store
    }

    /// The name the password of a connection is kept under.
    public static func account(of connection: SavedConnection) -> String {
        let key = connection.key
        let user = connection.anonymous ? "" : connection.user
        return "\(connection.id.uuidString) \(key.scheme)://\(user)@\(key.host):\(key.port)"
    }

    /// The certificates by host that `text` holds as JSON; none when it is missing or damaged.
    private static func decode(_ text: String?) -> [String: [String]] {
        guard let text, let all = try? JSONDecoder().decode([String: [String]].self, from: Data(text.utf8)) else {
            return [:]
        }
        return all
    }

    /// Tells which connections exist.
    ///
    /// Cheap; called on the main thread whenever the list changed. The first call also moves the
    /// passwords an earlier version kept by identifier alone, once.
    public func setConnections(_ connections: [SavedConnection]) {
        var current: [UUID: String] = [:]
        for connection in connections { current[connection.id] = Self.account(of: connection) }
        lock.lock()
        let isFirst = accounts.isEmpty
        accounts = current
        lock.unlock()
        guard isFirst, !current.isEmpty else {
            return
        }
        queue.async { [store, current] in
            guard store.password(for: Self.boundAccount) == nil else {
                return
            }
            for (id, account) in current {
                guard let old = store.password(for: id.uuidString) else { continue }
                if store.password(for: account) == nil { store.setPassword(old, for: account) }
                store.setPassword(nil, for: id.uuidString)
            }
            store.setPassword("1", for: Self.boundAccount)
        }
    }

    /// The account of the saved connection `id` as the connections are now; nil for one not known.
    private func account(of id: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return accounts[id]
    }

    /// The stored password for a login that comes from a saved connection; nil when the
    /// connection is not known as it is now (its host or user is not the one the password was
    /// stored for).
    ///
    /// Waits for the store: for connecting threads, never the main thread.
    public func password(for profile: ConnectionProfile) -> String? {
        guard let id = profile.savedID, let account = account(of: id) else {
            return nil
        }
        return queue.sync { store.password(for: account) }
    }

    /// Stores, or with nil removes, the password of a connection.
    ///
    /// Returns at once.
    public func setPassword(_ password: String?, for connection: SavedConnection) {
        let account = Self.account(of: connection)
        queue.async { [store] in store.setPassword(password, for: account) }
    }

    /// Gives `connection` the password that `original` has: for a copy of a connection, and
    /// for a connection whose host or user the user changed in the dialog.
    ///
    /// With `removing`, the original's is removed afterwards. Returns at once.
    public func carryPassword(from original: SavedConnection, to connection: SavedConnection, removing: Bool) {
        let (source, target) = (Self.account(of: original), Self.account(of: connection))
        guard source != target else {
            return
        }
        queue.async { [store] in
            if let password = store.password(for: source) { store.setPassword(password, for: target) }
            if removing { store.setPassword(nil, for: source) }
        }
    }

    /// The certificates the user accepted for good, by host.
    ///
    /// Waits for the store.
    public func trustedCertificates() -> [String: [String]] {
        queue.sync { [store] in Self.decode(store.password(for: Self.trustedAccount)) }
    }

    /// Makes `fingerprints` the certificates accepted for good for `host`, in place of what was
    /// stored for it, or with `adding` in addition to it.
    ///
    /// Returns at once.
    public func setTrusted(_ fingerprints: [String], for host: String, adding: Bool) {
        let server = host.lowercased()
        queue.async { [store] in
            var all = Self.decode(store.password(for: Self.trustedAccount))
            let kept = adding ? (all[server] ?? []).filter { !fingerprints.contains($0) } : []
            all[server] = kept + fingerprints
            // A dictionary of strings is always written, as UTF-8.
            if let data = try? JSONEncoder().encode(all), let text = String(bytes: data, encoding: .utf8) {
                store.setPassword(text, for: Self.trustedAccount)
            }
        }
    }

    /// Whether a certificate is stored for good for `host`.
    ///
    /// Waits for the store.
    public func hasTrusted(for host: String) -> Bool {
        !(trustedCertificates()[host.lowercased()] ?? []).isEmpty
    }

    /// Waits until everything that was queued is done; for tests.
    public func waitUntilDone() {
        queue.sync {
            // Nothing to do: once this runs, everything queued before it has run.
        }
    }

    deinit {
        // Nothing to release.
    }
}
