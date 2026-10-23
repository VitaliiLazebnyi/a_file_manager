public import AFMKernel
import Foundation

/// The servers the program is connected to, and how to reach the ones it is not connected to
/// yet (spec 11 › A connection is a panel location).
///
/// The file-system providers find their sessions here by the server part of a URL; a URL of a
/// server without a session connects on first use, with a saved connection's settings when one fits
/// and as an anonymous guest otherwise.
///
/// **Threading.** Safe from any thread; the state is guarded by a lock. `onChange` is called on
/// the thread that connected or disconnected.
///
/// All mutable state is guarded by `lock`, `makeSession`, `storedPassword` and `agentName` too
/// (they are set while the plugin starts, and by tests).
public final class ConnectionCenter: @unchecked Sendable {
    /// The options, the certificates trusted and the questions the sessions share.
    public let environment: SessionEnvironment
    /// Guards every member below.
    private let lock = NSLock()
    /// The session of each server in use, connected or not yet.
    private var sessions: [ServerKey: any RemoteSession] = [:]
    /// How to log in to a server, as a dialog or a typed address said; before the saved connections.
    private var announced: [ServerKey: ConnectionProfile] = [:]
    /// The logins of the saved connections.
    private var saved: [ConnectionProfile] = []
    /// The folder last listed on each server.
    private var lastPaths: [ServerKey: String] = [:]
    /// Builds the session for a profile; the plugin sets it for the protocols it speaks.
    internal var makeSession: @Sendable (ConnectionProfile, SessionEnvironment) -> (any RemoteSession)? {
        get { lock.withLock { sessionMaker } }
        set { lock.withLock { sessionMaker = newValue } }
    }
    /// What `makeSession` is; until the plugin sets it, no protocol has a session.
    private var sessionMaker: @Sendable (ConnectionProfile, SessionEnvironment) -> (any RemoteSession)? = { _, _ in
        nil
    }
    /// The stored password of a saved connection: of this very server and login, not of
    /// whatever connection carries the same identifier.
    ///
    /// Called on the thread that connects.
    public var storedPassword: @Sendable (ConnectionProfile) -> String? {
        get { lock.withLock { passwordSource } }
        set { lock.withLock { passwordSource = newValue } }
    }
    /// What `storedPassword` is; until the plugin sets it, no password is stored.
    private var passwordSource: @Sendable (ConnectionProfile) -> String? = { _ in nil }
    /// The servers the user chose to connect to (a saved connection, the connection dialogs, an
    /// earlier yes).
    ///
    /// A server that is none of these is asked about before the first login.
    private var chosen: Set<ServerKey> = []

    /// The name of this program, for the mark on what it downloads (`RemoteFileSystem.quarantine`).
    public var agentName: String {
        get { lock.withLock { programName } }
        set { lock.withLock { programName = newValue } }
    }
    /// What `agentName` is.
    private var programName = "A File Manager"

    /// The servers with a login that succeeded, in the order of their names.
    public var connected: [ConnectionProfile] {
        lock.lock()
        let all = Array(sessions.values)
        lock.unlock()
        return all.filter(\.isConnected).map(\.profile).sorted { $0.key.description < $1.key.description }
    }

    /// A center without sessions whose sessions share `environment`.
    public init(environment: SessionEnvironment = SessionEnvironment()) {
        self.environment = environment
    }

    /// Makes a profile known before its server is first used: a quick connection, or the user
    /// name and password that were part of a typed URL.
    ///
    /// `chosen` says that the user asked for this connection (a dialog of this program). An
    /// address that merely stood somewhere (a typed location, a tab file, a list) is announced
    /// without it, and the user is asked before the first login to its server.
    public func announce(_ profile: ConnectionProfile, chosen isChosen: Bool = false) {
        lock.lock()
        let isNewlyChosen = isChosen && chosen.insert(profile.key).inserted
        // Announced again as it is known already (a location that is read once more): nothing changes.
        if !isNewlyChosen, let known = announced[profile.key],
            (known.user, known.password, known.tls, known.anonymous, known.savedID)
                == (profile.user, profile.password, profile.tls, profile.anonymous, profile.savedID)
        {
            lock.unlock()
            return
        }
        announced[profile.key] = profile
        let stale = dropUnconnected([profile.key])
        lock.unlock()
        for session in stale { session.disconnect() }
    }

    /// The user named this server in person just now (an address typed into the command line or
    /// the path field): it is not asked about before the first login.
    ///
    /// Nothing else changes; how to log in is what `announce` or a saved connection said.
    public func noteChosen(_ key: ServerKey) {
        lock.lock()
        // A session made before this was known would still ask; one that is logging in is left alone.
        let stale = chosen.insert(key).inserted ? dropUnconnected([key]) : []
        lock.unlock()
        for session in stale { session.disconnect() }
    }

    /// Takes out the sessions of these servers that never got as far as a login, so the next
    /// attempt starts with what is known now.
    ///
    /// A session that is in the middle of its login is left alone: the user may be answering its
    /// question. Called with the lock held.
    private func dropUnconnected(_ keys: [ServerKey]) -> [any RemoteSession] {
        keys.compactMap { key in
            guard let session = sessions[key], !session.isConnected, !session.isConnecting else {
                return nil
            }
            sessions[key] = nil
            return session
        }
    }

    /// The saved connections, for URLs that name one of their servers.
    public func setSaved(_ profiles: [ConnectionProfile]) {
        lock.lock()
        saved = profiles
        let stale = dropUnconnected(profiles.map(\.key))
        lock.unlock()
        for session in stale { session.disconnect() }
    }

    /// How to log in to a server: as announced, else as a saved connection says, else as a guest.
    ///
    /// The profile asks before connecting unless the user chose the server; a saved connection's
    /// password is read from the store, which may wait for the Keychain.
    private func profile(for key: ServerKey) -> ConnectionProfile {
        lock.lock()
        let fromSaved = saved.first { $0.key == key }
        let known = announced[key] ?? fromSaved
        let isChosen = chosen.contains(key) || fromSaved != nil
        lock.unlock()
        guard var profile = known else {
            // Nothing is known: a guest on an FTP server, the Mac's user on a secure shell
            // (with the keys and the configuration that user has). Not without asking.
            var guest = ConnectionProfile(
                key: key,
                user: key.scheme == "sftp" ? NSUserName() : nil,
                anonymous: key.scheme != "sftp"
            )
            guest.asksBeforeConnecting = !isChosen
            return guest
        }
        profile.asksBeforeConnecting = !isChosen
        if profile.password == nil, profile.savedID != nil { profile.password = storedPassword(profile) }
        return profile
    }

    /// The session of a server, made (not yet connected) when there is none.
    ///
    /// Throws `FileSystemError.notSupported` for a scheme no session is made for.
    internal func session(for key: ServerKey) throws -> any RemoteSession {
        lock.lock()
        if let session = sessions[key] {
            lock.unlock()
            return session
        }
        lock.unlock()
        // The password comes from the Keychain, which may take a moment; not under the lock.
        let profile = self.profile(for: key)
        guard let created = makeSession(profile, environment) else {
            throw FileSystemError.notSupported("Connections of the type \(key.scheme)")
        }
        lock.lock()
        defer { lock.unlock() }
        if let session = sessions[key] {
            return session
        }
        sessions[key] = created
        return created
    }

    /// The session of a server when there is one.
    internal func existingSession(for key: ServerKey) -> (any RemoteSession)? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[key]
    }

    /// Whether the server has a session whose login succeeded.
    public func isConnected(_ key: ServerKey) -> Bool {
        existingSession(for: key)?.isConnected ?? false
    }

    /// The profile a live session was opened with.
    public func profile(of key: ServerKey) -> ConnectionProfile? {
        existingSession(for: key)?.profile
    }

    /// Connects if necessary; returns the folder the login leads to.
    public func connect(_ key: ServerKey, cancellation: CancellationFlag? = nil) throws -> String {
        try session(for: key).connect(cancellation: cancellation)
    }

    /// Forgets the connection to a server and closes it (`detach(_:)`, with the closing done here).
    public func disconnect(_ key: ServerKey) {
        detach(key)()
    }

    /// Forgets the connection at once and returns the work that closes it, which waits for
    /// the server and is therefore run off the main thread.
    public func detach(_ key: ServerKey) -> () -> Void {
        lock.lock()
        let session = sessions.removeValue(forKey: key)
        announced[key] = nil
        lastPaths[key] = nil
        chosen.remove(key)
        lock.unlock()
        return { session?.disconnect() }
    }

    /// Forgets every connection and closes them all (`RemoteSession.disconnect()`).
    public func disconnectAll() {
        lock.lock()
        let all = Array(sessions.values)
        sessions = [:]
        announced = [:]
        lock.unlock()
        for session in all { session.disconnect() }
    }

    /// Remembers `path` as the folder last listed on the server, for its entry in the volume list.
    internal func noteVisited(_ path: String, on key: ServerKey) {
        lock.lock()
        lastPaths[key] = path
        lock.unlock()
    }

    /// The folder last listed on a server.
    public func lastPath(on key: ServerKey) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lastPaths[key]
    }

    deinit {
        // Nothing to release.
    }
}
