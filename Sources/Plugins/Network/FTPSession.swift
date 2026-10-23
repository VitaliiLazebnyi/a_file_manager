import AFMKernel
import Foundation

/// The connections to one FTP server (spec 11 › Connection model): a pool of logged-in control
/// connections, so that listings, questions about single files and transfers can run on
/// several threads at once, each on a connection of its own.
///
/// **Threading.** Called from any number of threads. The pool's state is guarded by
/// `condition`; a connection handed out belongs to the thread that asked until it is returned.
/// Commands wait while all `parallelConnections` are busy with commands, which never takes
/// long. A transfer keeps its connection for as long as the file is open, so connections tied
/// up by transfers do not count against that limit: when only those are left, another
/// connection is opened rather than making a command wait for a download to end (the copy job
/// asks about the next target while the source is still open). Transfers have limits of their
/// own, `parallelConnections` plus one, one for downloads and one for uploads: the next
/// transfer waits for a free slot, so the number of logins stays within what servers with a
/// limit per client allow. Downloads and uploads wait separately because a copy between two
/// folders of one server holds a download while it waits for an upload.
///
/// The pool's state, `returnGrace` and `stallLimit` included, is guarded by `condition`, and the
/// link observer by `observerLock`. That state is internal for the extensions in the other
/// `FTPSession+` files (login, pool, keep-alive, links, the session's calls); nothing else touches it.
internal final class FTPSession: RemoteSession, @unchecked Sendable {
    /// What a connection is held for while a file is open.
    internal enum TransferKind {
        /// A download, held by an `FTPReader`.
        case read
        /// An upload, held by an `FTPWriter`.
        case write
    }

    /// Open files may use this many connections more than `parallelConnections`, per direction.
    internal static let extraTransferConnections = 1
    /// How many links are looked into in the background after a listing.
    internal static let backgroundLinks = 512
    /// How long links are looked into in the background after a listing, in seconds.
    internal static let backgroundLinkTime: TimeInterval = 20
    /// Links asked about in one go before the connection is offered to whoever waits.
    internal static let backgroundLinkBatch = 8
    /// How long to wait before trying again when the server answers 421 at login: it has no
    /// room for another connection of ours until another one is closed.
    internal static let busyDelays: [TimeInterval] = [0.5, 1, 2, 3, 4]

    /// An idle connection older than this is tested before it is used again.
    internal static let trustedIdleTime: TimeInterval = 20
    /// The keep-alive stops after this long without real use (spec 11 › Field semantics).
    internal static let keepAliveLimit: TimeInterval = 3_600

    /// The questions, passwords, options, log and clock of the program around the session.
    internal let environment: SessionEnvironment
    /// Guards the pool's state; waits for a connection wait on it.
    internal let condition = NSCondition()
    /// The profile as the last successful login left it (user and password included).
    internal var currentProfile: ConnectionProfile
    /// Logged-in connections nobody holds.
    internal var idle: [FTPConnection] = []
    /// Connections handed out, by identity.
    internal var inUse: [ObjectIdentifier: FTPConnection] = [:]
    /// Connections that exist or are being opened.
    internal var total = 0
    /// How many connections are held by open files for reading, or reserved for one that is being opened.
    internal var readers = 0
    /// How many connections are held by open files for writing, or reserved for one that is being opened.
    internal var writers = 0
    /// Whether the server answers MLST, known after the first login; single questions are
    /// cheap then.
    internal var knowsMLST = true
    /// Whether the server's FEAT lists REST, so that a transfer can start part-way; known after the first login.
    internal var offersRestart = true
    /// Set by `disconnect`; a closed session opens nothing again.
    internal var isClosed = false
    /// Whether a login has succeeded.
    internal var hasConnected = false
    /// The directory the first login led to.
    internal var home = "/"
    /// When a connection was last handed out, by the environment's clock.
    internal var lastActivity = Date()
    /// Counts the first logins that ended, and keeps the error of the last one that failed:
    /// threads that waited behind a login the user gave up get its error instead of a dialog.
    internal var loginRounds = 0
    /// The error of the last first login that failed (see `loginRounds`).
    internal var loginFailure: (any Error)?
    /// Whether the server refused SITE CHMOD, so it is not asked for every file.
    internal var refusesChmod = false
    /// Where the links of this server lead, for all connections.
    internal let links = LinkMemory()
    /// The names of this server that are written back as they came, for all connections.
    internal let names = NameMemory()
    /// Guards `linkObserver`.
    internal let observerLock = NSLock()
    /// Told where a link leads when the background finds out (see `onLinkResolved`).
    internal var linkObserver: (@Sendable (String, Bool) -> Void)?
    /// When the user last refused to give a password, to trust the certificate or to connect.
    internal var declined: (error: any Error, at: Date)?
    /// Held while the first connection is made, and whenever the user is asked something, so
    /// the user is asked once and the threads behind use the answer.
    internal let loginLock = NSLock()
    /// The timer of the keep-alive, while it runs.
    internal var keepAlive: (any DispatchSourceTimer)?
    /// The queue the keep-alive timer fires on.
    internal let keepAliveQueue = DispatchQueue(label: "afm.network.keepalive")
    /// Set by `disconnect`: ends every wait of this session that has no flag of its own.
    internal let closing = CancellationFlag()
    /// Logins under way.
    internal var loggingIn = 0
    /// Questions the user has not answered yet.
    internal var asking = 0
    /// When a server last showed a sign of life on any connection, or the user answered a
    /// question: a wait for a connection goes on for as long as things move.
    internal var lastProgress = Date()
    /// Threads that wait for a connection to run a command on.
    internal var commandWaiters = 0
    /// Connections of readers that were closed in the middle of a file: the server is being told
    /// in the background, and each comes back to the pool in a moment (see `FTPReader.close`).
    internal var returning = 0
    /// See `returnGrace`.
    internal var grace: TimeInterval = 0.5
    /// A connection the keep-alive is testing; it is in nobody's hands and not counted against the limit.
    internal var pinged: FTPConnection?
    /// Whether a round of the keep-alive is under way.
    internal var isPinging = false
    /// The user agreed to connect to this server.
    internal var mayConnect = false
    /// The user agreed to send the password without encryption.
    internal var mayGoUnprotected = false
    /// The links (full paths) still to be asked about in the background, newest listing first.
    internal var pendingLinks: [String] = []
    /// Whether the background resolver of links runs.
    internal var isResolving = false
    /// By the environment's clock, as the ages of the connections.
    internal var linkDeadline = Date()
    /// How often the resolver found no connection it may use and put its links back.
    internal var linksPutBack = 0
    /// See `stallLimit`.
    internal var stallTime: TimeInterval?

    /// How long a thread that needs a connection waits for one of those, or for one the
    /// keep-alive is testing at that moment, before it opens another: on a server that answers,
    /// the one coming back is there sooner than a new login.
    ///
    /// Tests lengthen it.
    internal var returnGrace: TimeInterval {
        get { condition.withLock { grace } }
        set { condition.withLock { grace = newValue } }
    }

    /// How long a wait for a connection, or for another thread's login, goes on while nothing
    /// moves on any connection of the session and no question is open.
    ///
    /// Tests shorten it.
    internal var stallLimit: TimeInterval? {
        get { condition.withLock { stallTime } }
        set { condition.withLock { stallTime = newValue } }
    }

    /// The connections held by open files, both ways.
    internal var transfers: Int { readers + writers }
    /// How long a wait goes on while nothing moves (see `stallLimit`).
    ///
    /// Called with the lock held.
    internal var patience: TimeInterval { stallTime ?? max(60, 2 * environment.options.values.timeout) }

    /// How the session reaches and logs in to its server, as the last login left it.
    internal var profile: ConnectionProfile {
        condition.lock()
        defer { condition.unlock() }
        return currentProfile
    }

    /// True once a login has succeeded, until `disconnect`.
    internal var isConnected: Bool {
        condition.lock()
        defer { condition.unlock() }
        return hasConnected && !isClosed
    }

    /// True while a login is under way (also while it waits for the user's answer).
    internal var isConnecting: Bool {
        condition.lock()
        defer { condition.unlock() }
        return loggingIn > 0 && !isClosed
    }

    /// How many connections are open, for tests.
    internal var connectionCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return total
    }

    /// How many threads wait for a connection to run a command on, for tests.
    internal var waitingCommands: Int { condition.withLock { commandWaiters } }

    /// How often the link resolver found no connection it may use (none free, or one that would ask the user
    /// something to log in) and put its links back, for tests.
    internal var linkRoundsPutBack: Int { condition.withLock { linksPutBack } }

    /// False for a server without MLST, where one question costs several commands and a listing.
    internal var singleLookupsAreCheap: Bool {
        condition.lock()
        defer { condition.unlock() }
        return knowsMLST
    }

    /// Seconds to wait for an answer or for data, from the options.
    internal var timeout: TimeInterval { environment.options.values.timeout }

    /// A session that connects when it is first used.
    internal init(profile: ConnectionProfile, environment: SessionEnvironment) {
        currentProfile = profile
        self.environment = environment
    }

    /// True for an address of this machine: nothing sent there crosses a network.
    internal static func isLoopback(_ host: String) -> Bool {
        let lowered = host.lowercased()
        return lowered == "localhost" || lowered == "::1" || lowered.hasPrefix("127.")
    }

    /// A reader that was closed hands its connection to the background, which gives it back
    /// (`release`) once the server was told; `change` is +1 before and -1 after.
    internal func noteReturning(_ change: Int) {
        condition.lock()
        returning += change
        condition.broadcast()
        condition.unlock()
    }

    /// The server showed a sign of life: whoever waits for a connection waits on.
    internal func noteProgress() {
        condition.lock()
        lastProgress = Date()
        condition.unlock()
    }

    /// The error for a wait that nothing ended: nil while things move or a question is open.
    ///
    /// Called with the lock held.
    internal func stalled(since began: Date, _ what: String) -> (any Error)? {
        guard asking == 0, Date().timeIntervalSince(max(began, lastProgress)) > patience else {
            return nil
        }
        return NetworkError.busy(what)
    }

    deinit { keepAlive?.cancel() }
}
