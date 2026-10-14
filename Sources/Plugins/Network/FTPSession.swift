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
/// link observer by `observerLock`.
final class FTPSession: RemoteSession, @unchecked Sendable {
    /// What a connection is held for while a file is open.
    fileprivate enum TransferKind { case read, write }

    private let environment: SessionEnvironment
    private let condition = NSCondition()
    private var currentProfile: ConnectionProfile
    private var idle: [FTPConnection] = []
    private var inUse: [ObjectIdentifier: FTPConnection] = [:]
    /// Connections that exist or are being opened.
    private var total = 0
    /// How many of them are held by open files, or reserved for one that is being opened.
    private var readers = 0
    private var writers = 0
    private var transfers: Int { readers + writers }
    /// Whether the server answers MLST, known after the first login; single questions are
    /// cheap then.
    private var knowsMLST = true
    /// Whether the server's FEAT lists REST, so that a transfer can start part-way; known after the first login.
    private var offersRestart = true
    private var isClosed = false
    private var hasConnected = false
    private var home = "/"
    private var lastActivity = Date()
    /// Counts the first logins that ended, and keeps the error of the last one that failed:
    /// threads that waited behind a login the user gave up get its error instead of a dialog.
    private var loginRounds = 0
    private var loginFailure: any Error?
    private var refusesChmod = false
    /// Where the links of this server lead, for all connections.
    private let links = LinkMemory()
    /// The names of this server that are written back as they came, for all connections.
    private let names = NameMemory()
    private let observerLock = NSLock()
    private var linkObserver: (@Sendable (String, Bool) -> Void)?
    /// When the user last refused to give a password, to trust the certificate or to connect.
    private var declined: (error: any Error, at: Date)?
    /// Held while the first connection is made, and whenever the user is asked something, so
    /// the user is asked once and the threads behind use the answer.
    private let loginLock = NSLock()
    private var keepAlive: any DispatchSourceTimer?
    private let keepAliveQueue = DispatchQueue(label: "afm.network.keepalive")
    /// Set by `disconnect`: ends every wait of this session that has no flag of its own.
    private let closing = CancellationFlag()
    /// Logins under way, and questions the user has not answered yet.
    private var loggingIn = 0
    private var asking = 0
    /// When a server last showed a sign of life on any connection, or the user answered a
    /// question: a wait for a connection goes on for as long as things move.
    private var lastProgress = Date()
    /// Threads that wait for a connection to run a command on.
    private var commandWaiters = 0
    /// Connections of readers that were closed in the middle of a file: the server is being told
    /// in the background, and each comes back to the pool in a moment (see `FTPReader.close`).
    private var returning = 0
    /// How long a thread that needs a connection waits for one of those, or for one the
    /// keep-alive is testing at that moment, before it opens another: on a server that answers,
    /// the one coming back is there sooner than a new login. Tests lengthen it.
    var returnGrace: TimeInterval {
        get { condition.withLock { grace } }
        set { condition.withLock { grace = newValue } }
    }
    private var grace: TimeInterval = 0.5
    /// A connection the keep-alive is testing; it is in nobody's hands and not counted against the limit.
    private var pinged: FTPConnection?
    private var isPinging = false
    /// The user agreed to connect to this server, and to send the password without encryption.
    private var mayConnect = false
    private var mayGoUnprotected = false
    /// The links (full paths) still to be asked about in the background, newest listing first.
    private var pendingLinks: [String] = []
    private var isResolving = false
    private var linkDeadline = Date()

    /// Open files may use this many connections more than `parallelConnections`, per direction.
    private static let extraTransferConnections = 1
    /// How many links, and for how long, are looked into in the background after a listing.
    private static let backgroundLinks = 512
    private static let backgroundLinkTime: TimeInterval = 20
    /// Links asked about in one go before the connection is offered to whoever waits.
    private static let backgroundLinkBatch = 8
    /// How long to wait before trying again when the server answers 421 at login: it has no
    /// room for another connection of ours until another one is closed.
    private static let busyDelays: [TimeInterval] = [0.5, 1, 2, 3, 4]

    /// An idle connection older than this is tested before it is used again.
    private static let trustedIdleTime: TimeInterval = 20
    /// The keep-alive stops after this long without real use (spec 11 › Field semantics).
    private static let keepAliveLimit: TimeInterval = 3_600

    /// How long a wait for a connection, or for another thread's login, goes on while nothing
    /// moves on any connection of the session and no question is open. Tests shorten it.
    var stallLimit: TimeInterval? {
        get { condition.withLock { stallTime } }
        set { condition.withLock { stallTime = newValue } }
    }
    private var stallTime: TimeInterval?
    /// Called with the lock held.
    private var patience: TimeInterval { stallTime ?? max(60, 2 * environment.options.values.timeout) }

    init(profile: ConnectionProfile, environment: SessionEnvironment) {
        currentProfile = profile
        self.environment = environment
    }

    deinit { keepAlive?.cancel() }

    var profile: ConnectionProfile {
        condition.lock()
        defer { condition.unlock() }
        return currentProfile
    }

    var isConnected: Bool {
        condition.lock()
        defer { condition.unlock() }
        return hasConnected && !isClosed
    }

    var isConnecting: Bool {
        condition.lock()
        defer { condition.unlock() }
        return loggingIn > 0 && !isClosed
    }

    /// How many connections are open, for tests.
    var connectionCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return total
    }

    /// A reader that was closed hands its connection to the background, which gives it back
    /// (`release`) once the server was told; `change` is +1 before and -1 after.
    fileprivate func noteReturning(_ change: Int) {
        condition.lock()
        returning += change
        condition.broadcast()
        condition.unlock()
    }

    /// The server showed a sign of life: whoever waits for a connection waits on.
    fileprivate func noteProgress() {
        condition.lock()
        lastProgress = Date()
        condition.unlock()
    }

    /// The error for a wait that nothing ended: nil while things move or a question is open.
    /// Called with the lock held.
    private func stalled(since began: Date, _ what: String) -> any Error? {
        guard asking == 0, Date().timeIntervalSince(max(began, lastProgress)) > patience else { return nil }
        return NetworkError.busy(what)
    }

    // MARK: Opening connections

    private func config(for profile: ConnectionProfile) -> FTPServerConfig {
        let options = environment.options.values
        return FTPServerConfig(
            host: profile.key.host, port: profile.key.port, tls: profile.tls, user: profile.user ?? "anonymous",
            password: profile.password ?? "", passive: profile.passive ?? options.passiveByDefault,
            encoding: profile.encoding, timeout: options.timeout, initCommands: profile.initCommands,
            usesMLSD: profile.usesMLSD)
    }

    /// The user said no to a question; the connection is not made.
    private struct Refusal: Error {
        let error: any Error
    }

    private func takeLoginLock(cancellation: CancellationFlag?) throws {
        let began = Date()
        try lockPatiently(loginLock, cancellation: cancellation) {
            self.condition.lock()
            defer { self.condition.unlock() }
            if self.isClosed { return NetworkError.notConnected(self.currentProfile.key.description) }
            return self.stalled(
                since: began, "Another login to \(self.currentProfile.key.description) is still under way.")
        }
    }

    /// Asks the user something on behalf of a login. Every question is asked with `loginLock`
    /// held, so several threads do not each raise a dialog; `holdsLock` tells whether this
    /// thread has it already and is set when it is taken here. Work in the background asks
    /// nothing. Nil is the user's refusal.
    private func ask<Answer>(
        holdsLock: inout Bool, background: Bool, cancellation: CancellationFlag?, _ question: () -> Answer?
    ) throws -> Answer? {
        if background { throw NetworkError.busy("A question to the user is not asked from the background.") }
        if !holdsLock {
            try takeLoginLock(cancellation: cancellation)
            holdsLock = true
        }
        condition.lock()
        if let declined, Date().timeIntervalSince(declined.at) < environment.declineMemory {
            condition.unlock()
            throw declined.error
        }
        asking += 1
        condition.unlock()
        defer {
            condition.lock()
            asking -= 1
            lastProgress = Date()
            condition.unlock()
        }
        return question()
    }

    /// True for an address of this machine: nothing sent there crosses a network.
    static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

    /// Opens and logs in one more connection, asking the user for what is missing: consent to
    /// a server nobody chose, a password, or consent to a certificate the system does not trust.
    /// `background` work asks nothing and fails instead.
    private func openConnection(cancellation: CancellationFlag?, background: Bool = false) throws -> FTPConnection {
        var holdsLock = false
        defer { if holdsLock { loginLock.unlock() } }
        condition.lock()
        let wasFirst = !hasConnected
        let roundsBefore = loginRounds
        condition.unlock()
        if wasFirst {
            try takeLoginLock(cancellation: cancellation)
            holdsLock = true
        }

        condition.lock()
        // Read again: another thread may have logged in while this one waited for the lock.
        let isFirst = !hasConnected
        if isFirst, loginRounds != roundsBefore, let loginFailure {
            condition.unlock()
            throw loginFailure
        }
        if let declined, Date().timeIntervalSince(declined.at) < environment.declineMemory {
            condition.unlock()
            throw declined.error
        }
        var profile = currentProfile
        loggingIn += 1
        condition.unlock()
        defer {
            condition.lock()
            loggingIn -= 1
            condition.unlock()
        }
        if holdsLock, !isFirst {
            // The login is made; the others no longer wait for this one.
            loginLock.unlock()
            holdsLock = false
        }

        var refused = false
        var remember = false
        /// Asks for the user name and password, unless another thread got them meanwhile.
        func credentials(_ message: String) throws {
            let tried = (profile.user, profile.password)
            let hadLock = holdsLock
            let answer = try ask(holdsLock: &holdsLock, background: background, cancellation: cancellation) {
                () -> Credentials?? in
                if !hadLock {
                    // Waited for another thread's question: its answer, once a login accepted it, is used.
                    condition.lock()
                    let now = currentProfile
                    condition.unlock()
                    if now.user != nil, (now.user, now.password) != tried { return .some(nil) }
                }
                return environment.askCredentials(profile, message).map { .some($0) }
            }
            guard let answer else {
                refused = true
                throw message.isEmpty ? NetworkError.cancelled : NetworkError.loginFailed(message)
            }
            if let answer {
                (profile.user, profile.password, profile.anonymous) = (answer.user, answer.password, false)
                remember = answer.remember
            } else {
                condition.lock()
                (profile.user, profile.password, profile.anonymous) = (
                    currentProfile.user, currentProfile.password, currentProfile.anonymous
                )
                condition.unlock()
            }
        }

        do {
            condition.lock()
            let (asksFirst, knowsUnprotected) = (profile.asksBeforeConnecting && !mayConnect, mayGoUnprotected)
            condition.unlock()
            if asksFirst {
                guard
                    try ask(
                        holdsLock: &holdsLock, background: background, cancellation: cancellation,
                        { environment.askToConnect(profile) ? true : nil }) != nil
                else {
                    refused = true
                    throw NetworkError.cancelled
                }
                condition.lock()
                mayConnect = true
                condition.unlock()
            }
            if profile.user == nil {
                if profile.anonymous {
                    (profile.user, profile.password) = ("anonymous", environment.options.values.anonymousPassword)
                } else {
                    try credentials("")
                }
            } else if profile.password == nil, profile.user != "anonymous" {
                try credentials("")
            }
            var attempts = 0
            var askedUnprotected = knowsUnprotected
            while true {
                attempts += 1
                // A password on plain FTP can be read by anyone on the way.
                if profile.tls == .none, profile.user != "anonymous", !(profile.password ?? "").isEmpty,
                    !askedUnprotected,
                    environment.asksAboutUnprotectedLoopback || !Self.isLoopback(profile.key.host)
                {
                    guard
                        try ask(
                            holdsLock: &holdsLock, background: background, cancellation: cancellation,
                            { environment.askToSendPasswordUnprotected(profile) ? true : nil }) != nil
                    else {
                        refused = true
                        throw NetworkError.cancelled
                    }
                    askedUnprotected = true
                    condition.lock()
                    mayGoUnprotected = true
                    condition.unlock()
                }
                let connection = FTPConnection(
                    config: config(for: profile), trust: environment.trust, knownLinks: links, knownNames: names,
                    onActivity: { [weak self] in self?.noteProgress() }, log: environment.log)
                do {
                    try connection.connect(cancellation: cancellation ?? closing)
                    condition.lock()
                    if !hasConnected {
                        home = connection.home
                        knowsMLST = connection.offers("MLST")
                        offersRestart = connection.offers("REST")
                    }
                    hasConnected = true
                    loginRounds += 1
                    loginFailure = nil
                    currentProfile = profile
                    lastProgress = Date()
                    condition.unlock()
                    // Kept only now that the server took it.
                    if remember, let password = profile.password { environment.rememberPassword(profile, password) }
                    startKeepAlive()
                    return connection
                } catch NetworkError.untrustedCertificate(let certificate) {
                    guard attempts < 4 else { throw NetworkError.untrustedCertificate(certificate) }
                    let host = profile.key.host
                    let hadLock = holdsLock
                    let accepted = try ask(holdsLock: &holdsLock, background: background, cancellation: cancellation) {
                        () -> Bool? in
                        // Another thread's answer to the same certificate is enough.
                        if !hadLock, environment.trust.isAccepted(certificate.fingerprint, for: host) { return true }
                        let known = environment.trust.fingerprints(for: host)
                        if known.isEmpty { return environment.askToTrust(profile, certificate) ? true : nil }
                        // Not the certificate the user accepted for this server: a question of its own.
                        return environment.askToTrustChanged(profile, certificate, known) ? true : nil
                    }
                    guard accepted != nil else {
                        refused = true
                        throw NetworkError.untrustedCertificate(certificate)
                    }
                } catch NetworkError.loginFailed(let message) {
                    guard attempts < 4 else { throw NetworkError.loginFailed(message) }
                    try credentials(message)
                }
            }
        } catch {
            condition.lock()
            loginRounds += 1
            // A login that was merely cancelled says nothing to the threads behind it, and is
            // not a refusal to remember: the next attempt tries again.
            if case NetworkError.cancelled = error, !refused { loginFailure = nil } else { loginFailure = error }
            if refused { declined = (error, Date()) }
            condition.unlock()
            throw error
        }
    }

    // MARK: The pool

    /// Hands out a connection. A `transfer` connection is kept for as long as a file is open.
    ///
    /// Every wait in here ends: when `cancellation` is set, when the session is closed, and when
    /// nothing has moved on any connection for `patience` seconds (then with an error that says
    /// what is in the way). `background` work never waits at all: it takes a connection that is
    /// free now, or fails.
    private func acquire(
        transfer: TransferKind?, fresh: Bool = false, background: Bool = false,
        cancellation: CancellationFlag?
    ) throws -> (connection: FTPConnection, reused: Bool) {
        let began = Date()
        /// After the server said it has no room for another connection (421): when to ask
        /// again, how often that was done, and what it said.
        var (openNotBefore, busyRetries, busyReply): (Date?, Int, FTPReply?) = (nil, 0, nil)
        while true {
            if cancellation?.isCancelled == true { throw NetworkError.cancelled }
            condition.lock()
            var candidate: FTPConnection?
            var mayOpen = false
            if transfer == nil, !background { commandWaiters += 1 }
            func leave(_ error: any Error) -> any Error {
                if transfer == nil, !background { commandWaiters -= 1 }
                condition.broadcast()
                condition.unlock()
                return error
            }
            while true {
                let server = currentProfile.key.description
                if isClosed { throw leave(NetworkError.notConnected(server)) }
                let limit = max(1, environment.options.values.parallelConnections)
                let hasSlot = transfer.map { holders(of: $0) < limit + Self.extraTransferConnections } ?? true
                if hasSlot {
                    if !fresh, let connection = idle.popLast() {
                        candidate = connection
                        break
                    }
                    let serverHasRoom =
                        busyRetries <= Self.busyDelays.count && (openNotBefore.map { Date() >= $0 } ?? true)
                    // A connection that is on its way back is waited for, for a moment.
                    let oneIsComing =
                        (returning > 0 || pinged != nil) && !fresh && Date().timeIntervalSince(began) < grace
                    // Connections held by open files are not coming back soon, and one the keep-alive tests is nobody's.
                    if serverHasRoom, !oneIsComing,
                        transfer != nil || total - transfers - (pinged == nil ? 0 : 1) < limit || fresh
                    {
                        total += 1
                        mayOpen = true
                        break
                    }
                }
                if background { throw leave(NetworkError.busy("No connection to \(server) is free.")) }
                if cancellation?.isCancelled == true { throw leave(NetworkError.cancelled) }
                if let error = stalled(
                    since: began,
                    hasSlot
                        ? "All connections to \(server) are in use and none came free."
                        : "All connections to \(server) for \(transfer == .read ? "downloads" : "uploads") are held by open files."
                ) {
                    throw leave(busyReply.map { NetworkError.refused($0) } ?? error)
                }
                condition.wait(until: Date().addingTimeInterval(returning > 0 || pinged != nil ? 0.05 : 0.2))
            }
            if transfer == nil, !background { commandWaiters -= 1 }
            // The slot is taken now, not when the connection is registered, so threads that
            // arrive together do not all see it free.
            if let transfer { adjust(transfer, by: 1) }
            lastActivity = Date()
            condition.unlock()

            if let connection = candidate {
                // A connection that sat idle may have been dropped by the server or a router.
                if Date().timeIntervalSince(connection.lastUsed) > Self.trustedIdleTime,
                    !connection.isAlive(cancellation: cancellation ?? closing)
                {
                    discard(connection, wasInUse: false, transfer: transfer)
                    continue
                }
                register(connection)
                return (connection, true)
            }
            if mayOpen {
                do {
                    let connection = try openConnection(cancellation: cancellation, background: background)
                    register(connection)
                    return (connection, false)
                } catch {
                    condition.lock()
                    total -= 1
                    if let transfer { adjust(transfer, by: -1) }
                    var again = false
                    if case NetworkError.refused(let reply) = error, reply.code == 421, hasConnected, !isClosed,
                        !background
                    {
                        // Too many connections from here. The slot is given back, and this
                        // thread takes a connection that comes free, or asks the server again
                        // after a while; when the server keeps saying no, only the former.
                        busyReply = reply
                        if busyRetries < Self.busyDelays.count {
                            openNotBefore = Date().addingTimeInterval(Self.busyDelays[busyRetries])
                        }
                        busyRetries += 1
                        again = true
                    }
                    condition.broadcast()
                    condition.unlock()
                    if !again { throw error }
                }
            }
        }
    }

    /// How many connections are held for files of this kind. Called with the lock held.
    private func holders(of kind: TransferKind) -> Int { kind == .read ? readers : writers }

    private func adjust(_ kind: TransferKind, by change: Int) {
        if kind == .read { readers += change } else { writers += change }
    }

    private func register(_ connection: FTPConnection) {
        condition.lock()
        inUse[ObjectIdentifier(connection)] = connection
        let closed = isClosed
        condition.unlock()
        // Disconnected while this connection was being opened.
        if closed { connection.interrupt() }
    }

    /// Takes a connection back; one that is no longer usable is closed.
    fileprivate func release(_ connection: FTPConnection, transfer: TransferKind?) {
        condition.lock()
        inUse[ObjectIdentifier(connection)] = nil
        if let transfer { adjust(transfer, by: -1) }
        let keep = connection.isUsable && !isClosed
        if keep {
            idle.append(connection)
        } else {
            total -= 1
        }
        lastProgress = Date()
        condition.broadcast()
        condition.unlock()
        if !keep { connection.close() }
    }

    private func discard(_ connection: FTPConnection, wasInUse: Bool, transfer: TransferKind? = nil) {
        condition.lock()
        if wasInUse { inUse[ObjectIdentifier(connection)] = nil }
        if let transfer { adjust(transfer, by: -1) }
        total -= 1
        condition.broadcast()
        condition.unlock()
        connection.close()
    }

    /// Runs a command sequence on a connection of the pool. When a connection that was idle
    /// turns out to be dead, the work is done once more on a new one (spec: reconnect on a
    /// dropped control connection). `mayRetry` is asked first, because work that already had
    /// an effect outside must not be repeated.
    private func perform<Result>(
        transfer: TransferKind? = nil, cancellation: CancellationFlag? = nil,
        mayRetry: (FTPConnection) -> Bool = { _ in true },
        _ work: (FTPConnection) throws -> Result
    ) throws -> (result: Result, connection: FTPConnection) {
        var (connection, reused) = try acquire(transfer: transfer, cancellation: cancellation)
        while true {
            do {
                let result = try work(connection)
                if transfer == nil { release(connection, transfer: nil) }
                return (result, connection)
            } catch let error as NetworkError
                where error.isConnectionLevel && reused && !connection.isUsable && mayRetry(connection)
            {
                discard(connection, wasInUse: true, transfer: transfer)
                (connection, reused) = (
                    try acquire(transfer: transfer, fresh: true, cancellation: cancellation).connection, false
                )
            } catch {
                release(connection, transfer: transfer)
                throw error
            }
        }
    }

    /// A command, or a few that belong together. One that must not happen twice (it creates,
    /// removes or renames) is repeated on a new connection only when the old one failed before
    /// the command was sent, or the server said it was closing (421): after a reply that did not
    /// come, the command may well have been carried out.
    private func command<Result>(
        repeatable: Bool = true, cancellation: CancellationFlag? = nil,
        _ work: (FTPConnection) throws -> Result
    ) throws -> Result {
        try perform(cancellation: cancellation, mayRetry: { repeatable || !$0.commandMayHaveRun }, work).result
    }

    // MARK: Keep-alive

    /// Sends NOOP on idle connections so the server does not close them, and closes the spare
    /// ones after a while to free the server's slots.
    private func startKeepAlive() {
        let interval = environment.options.values.keepAliveInterval
        condition.lock()
        defer { condition.unlock() }
        guard keepAlive == nil, interval > 0, !isClosed else { return }
        let timer = DispatchSource.makeTimerSource(queue: keepAliveQueue)
        let period = max(0.25, interval / 2)
        timer.schedule(deadline: .now() + period, repeating: period)
        // The timer only says when; the test waits for the server, which a dispatch queue must not.
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            condition.lock()
            let start = !isPinging && !isClosed
            if start { isPinging = true }
            condition.unlock()
            if start {
                Background.run(lane: self) { [weak self] in self?.keepIdleConnectionsAlive(interval: interval) }
            }
        }
        timer.resume()
        keepAlive = timer
    }

    /// Tests the idle connections that were not used for `interval`, one at a time: each is
    /// taken out of the pool for its test only, and while it is out it does not count against
    /// the limit, so a command never waits for a test to end.
    private func keepIdleConnectionsAlive(interval: TimeInterval) {
        var kept = 0
        var tested = Set<ObjectIdentifier>()
        while true {
            let now = Date()
            condition.lock()
            guard !isClosed,
                let index = idle.firstIndex(where: {
                    now.timeIntervalSince($0.lastUsed) >= interval && !tested.contains(ObjectIdentifier($0))
                })
            else {
                isPinging = false
                condition.unlock()
                return
            }
            let connection = idle.remove(at: index)
            tested.insert(ObjectIdentifier(connection))
            pinged = connection
            let resting = now.timeIntervalSince(lastActivity)
            // One connection is kept warm for an hour; the others go when nothing has happened for a while.
            let isTheOne = idle.isEmpty && kept == 0
            condition.unlock()
            let wanted = isTheOne ? resting < Self.keepAliveLimit : resting < max(120, interval * 2)
            let alive = wanted && connection.isAlive(cancellation: closing)
            condition.lock()
            pinged = nil
            let keep = alive && !isClosed
            if keep {
                idle.append(connection)
                kept += 1
            } else {
                total -= 1
            }
            condition.broadcast()
            condition.unlock()
            if !keep { connection.close() }
        }
    }

    // MARK: RemoteSession

    func connect(cancellation: CancellationFlag?) throws -> String {
        _ = try perform(cancellation: cancellation) { _ in }
        condition.lock()
        defer { condition.unlock() }
        return home
    }

    /// Returns at once: the connections in use are cut, every wait of the session ends, and
    /// the goodbye to the server on the idle ones is said in the background.
    func disconnect() {
        condition.lock()
        isClosed = true
        let (resting, busy, tested) = (idle, Array(inUse.values), pinged)
        idle = []
        total -= resting.count
        pendingLinks = []
        keepAlive?.cancel()
        keepAlive = nil
        condition.broadcast()
        condition.unlock()
        closing.cancel()
        busy.forEach { $0.interrupt() }
        tested?.interrupt()
        if !resting.isEmpty { Background.run(lane: self) { resting.forEach { $0.close() } } }
    }

    func list(_ path: String, showHidden: Bool, cancellation: CancellationFlag?, receive: ([RemoteEntry]) -> Bool)
        throws
    {
        var delivered = false
        var unresolved: [String] = []
        _ = try perform(cancellation: cancellation, mayRetry: { _ in !delivered }) { connection in
            try connection.list(path, showHidden: showHidden, cancellation: cancellation) { entries in
                delivered = true
                return receive(entries)
            }
            unresolved = connection.unresolvedLinks
        }
        if !unresolved.isEmpty, cancellation?.isCancelled != true { resolveLinksLater(unresolved) }
    }

    func onLinkResolved(_ handler: @escaping @Sendable (String, Bool) -> Void) {
        observerLock.withLock { linkObserver = handler }
    }

    /// The links a listing had no time to ask about are asked after it was delivered, on a
    /// connection of the pool; the next listing of the folder then knows where they lead.
    /// One resolver per session works through one list: the links of the newest listing come
    /// first, and what does not fit belongs to folders the user has left.
    private func resolveLinksLater(_ paths: [String]) {
        condition.lock()
        var seen = Set<String>()
        pendingLinks = Array(
            (paths + pendingLinks).filter { seen.insert($0).inserted }.prefix(Self.backgroundLinks))
        linkDeadline = Date().addingTimeInterval(Self.backgroundLinkTime)
        let start = !isResolving && !isClosed
        if start { isResolving = true }
        condition.unlock()
        if start { Background.run(lane: self) { [weak self] in self?.resolveLinks() } }
    }

    /// The resolver. It only ever uses a connection nobody else wants: it takes one that is
    /// free now (and opens none that would need a question to the user), asks about a few
    /// links, and gives it back; while a command waits for a connection it stands aside.
    private func resolveLinks() {
        while true {
            condition.lock()
            while commandWaiters > 0, !isClosed, !pendingLinks.isEmpty, Date() < linkDeadline {
                condition.wait(until: Date().addingTimeInterval(0.2))
            }
            guard !isClosed, !pendingLinks.isEmpty, Date() < linkDeadline else {
                pendingLinks = []
                isResolving = false
                condition.unlock()
                return
            }
            let batch = Array(pendingLinks.prefix(Self.backgroundLinkBatch))
            pendingLinks.removeFirst(batch.count)
            condition.unlock()

            guard let connection = try? acquire(transfer: nil, background: true, cancellation: closing).connection
            else {
                // Nothing is free right now; the links wait.
                condition.lock()
                pendingLinks = batch + pendingLinks
                if !isClosed { condition.wait(until: Date().addingTimeInterval(0.5)) }
                condition.unlock()
                continue
            }
            for (index, full) in batch.enumerated() where links.isDirectory(full) == nil {
                condition.lock()
                let yields = commandWaiters > 0 || isClosed
                if yields { pendingLinks = Array(batch[index...]) + pendingLinks }
                condition.unlock()
                if yields { break }
                guard let isDirectory = connection.probeLink(full, cancellation: closing) else { break }
                // Told first: whoever hears of the link here finds it resolved in the memory too.
                observerLock.withLock { linkObserver }?(full, isDirectory)
                links.remember(full, isDirectory: isDirectory)
            }
            release(connection, transfer: nil)
        }
    }

    func entry(at path: String, cancellation: CancellationFlag?) throws -> RemoteEntry? {
        let path = RemotePath.normalized(path)
        if path == "/" { return RemoteEntry(name: "/", isDirectory: true) }
        return try command(cancellation: cancellation) { connection in
            if connection.offers("MLST") { return try connection.status(of: path, cancellation: cancellation) }
            let name = RemotePath.name(of: path)
            if connection.offers("SIZE") {
                if let size = try connection.size(of: path, cancellation: cancellation) {
                    let modified =
                        connection.offers("MDTM")
                        ? try connection.modificationTime(of: path, cancellation: cancellation) : nil
                    return RemoteEntry(name: name, isDirectory: false, size: size, modified: modified)
                }
                if (try? connection.changeDirectory(path, cancellation: cancellation)) != nil {
                    return RemoteEntry(name: name, isDirectory: true)
                }
                // Neither a file whose size the server tells nor a directory to enter: the listing decides.
            }
            var found: RemoteEntry?
            try connection.list(RemotePath.parent(of: path) ?? "/", showHidden: true, cancellation: cancellation) {
                entries in
                found = entries.first { $0.name == name }
                return found == nil
            }
            return found
        }
    }

    // The four calls that change something end on the caller's flag, on `closing` when the
    // session is disconnected, and by the limits of `acquire`.

    func makeDirectory(_ path: String, cancellation: CancellationFlag?) throws {
        try withEither(closing, cancellation) { closing in
            try command(repeatable: false, cancellation: closing) { try $0.makeDirectory(path, cancellation: closing) }
        }
    }

    func remove(_ path: String, isDirectory: Bool?, cancellation: CancellationFlag?) throws {
        try withEither(closing, cancellation) { closing in try remove(path, isDirectory: isDirectory, ending: closing) }
    }

    private func remove(_ path: String, isDirectory: Bool?, ending closing: CancellationFlag) throws {
        try command(repeatable: false, cancellation: closing) { connection in
            if isDirectory == true { return try connection.removeDirectory(path, cancellation: closing) }
            do {
                try connection.deleteFile(path, cancellation: closing)
            } catch NetworkError.refused(let fileReply) where isDirectory == nil {
                // Nobody said what it is; a directory is removed with another command.
                do {
                    try connection.removeDirectory(path, cancellation: closing)
                } catch NetworkError.refused(let directoryReply) {
                    let isFile = directoryReply.text.range(of: "not a directory", options: .caseInsensitive) != nil
                    throw NetworkError.refused(isFile ? fileReply : directoryReply)
                }
            }
        }
    }

    /// FTP has one rename, and what it does to an existing destination is the server's choice.
    func rename(_ source: String, to destination: String, replacing _: Bool, cancellation: CancellationFlag?) throws {
        try withEither(closing, cancellation) { closing in
            try command(repeatable: false, cancellation: closing) {
                try $0.rename(source, to: destination, cancellation: closing)
            }
        }
    }

    func setAttributes(_ attributes: FileAttributes, of path: String, cancellation: CancellationFlag?) throws {
        try withEither(closing, cancellation) { closing in
            try command(cancellation: closing) { connection in
                if let modified = attributes.modified {
                    try connection.setModificationTime(modified, of: path, cancellation: closing)
                }
                if let permissions = attributes.permissions {
                    try connection.setPermissions(permissions, of: path, cancellation: closing)
                }
            }
        }
    }

    func openRead(_ path: String, cancellation: CancellationFlag?) throws -> any FileReader {
        if cancellation?.isCancelled == true { throw NetworkError.cancelled }
        return FTPReader(
            session: self, path: RemotePath.normalized(path),
            asText: environment.options.transfersAsText(RemotePath.name(of: path)))
    }

    func openWrite(_ path: String, cancellation: CancellationFlag?) throws -> any FileWriter {
        let path = RemotePath.normalized(path)
        let asText = environment.options.transfersAsText(RemotePath.name(of: path))
        let (stream, connection) = try perform(transfer: .write, cancellation: cancellation) {
            try $0.beginTransfer("STOR \(path)", type: asText ? "A" : "I", cancellation: cancellation)
        }
        return FTPWriter(session: self, connection: connection, stream: stream, path: path, asText: asText, start: 0)
    }

    /// Continuing needs a transfer in binary, so that the offsets are those of the file on the server.
    func canAppend(_ path: String) -> Bool {
        guard !environment.options.transfersAsText(RemotePath.name(of: path)) else { return false }
        condition.lock()
        defer { condition.unlock() }
        return !hasConnected || offersRestart
    }

    /// `APPE` where the file is continued at its end, else `REST` and `STOR` (RFC 3659). A server
    /// does not cut a file there, and one that does not know `APPE` may start the file anew, so
    /// the length is checked when the file is closed, as after every upload.
    func openAppend(_ path: String, at offset: Int64?, cancellation: CancellationFlag?) throws -> (
        writer: any FileWriter, size: Int64
    ) {
        let path = RemotePath.normalized(path)
        if environment.options.transfersAsText(RemotePath.name(of: path)) {
            throw FileSystemError.notSupported("Continuing a transfer in text mode")
        }
        let known = try command(cancellation: cancellation) { connection in
            connection.offers("SIZE") ? try connection.size(of: path, cancellation: cancellation) : nil
        }
        guard
            let size = try known
                ?? entry(at: path, cancellation: cancellation).flatMap({ $0.isDirectory ? nil : $0.size })
        else {
            throw NetworkError.refused(FTPReply(code: 550, lines: ["No such file"]))
        }
        let target = offset ?? size
        guard target >= 0, target <= size else {
            throw FileSystemError.notSupported("Continuing \(path) at \(target), it has \(size) bytes")
        }
        let (stream, connection) = try perform(transfer: .write, cancellation: cancellation) { connection in
            guard target == size || connection.offers("REST") else {
                throw FileSystemError.notSupported("Continuing a file on this server")
            }
            return try connection.beginTransfer(
                target == size ? "APPE \(path)" : "STOR \(path)", type: "I",
                restartAt: target == size ? 0 : UInt64(target), cancellation: cancellation)
        }
        return (
            FTPWriter(session: self, connection: connection, stream: stream, path: path, asText: false, start: target),
            target
        )
    }

    /// Starts a download at `offset` on a connection of its own.
    fileprivate func beginDownload(
        _ path: String, asText: Bool, offset: UInt64,
        cancellation: CancellationFlag?
    ) throws -> (stream: NetStream, connection: FTPConnection) {
        let (stream, connection) = try perform(transfer: .read, cancellation: cancellation) {
            try $0.beginTransfer(
                "RETR \(path)", type: asText ? "A" : "I", restartAt: offset, cancellation: cancellation)
        }
        return (stream, connection)
    }

    /// Date and permissions of a file that was just uploaded, as far as the server takes them.
    fileprivate func applyAfterUpload(_ attributes: FileAttributes, to path: String, on connection: FTPConnection) {
        if let modified = attributes.modified, connection.offers("MFMT") {
            try? connection.setModificationTime(modified, of: path)
        }
        condition.lock()
        let triesChmod = !refusesChmod
        condition.unlock()
        guard let permissions = attributes.permissions, triesChmod else { return }
        do {
            try connection.setPermissions(permissions, of: path)
        } catch NetworkError.refused(let reply) where [500, 502, 504].contains(reply.code) {
            // A server without chmod is not asked for every file.
            condition.lock()
            refusesChmod = true
            condition.unlock()
        } catch {}
    }

    /// False for a server without MLST, where one question costs several commands and a listing.
    var singleLookupsAreCheap: Bool {
        condition.lock()
        defer { condition.unlock() }
        return knowsMLST
    }

    fileprivate var timeout: TimeInterval { environment.options.values.timeout }
}

/// A file on an FTP server being downloaded (`RETR`). The transfer starts with the first read
/// and holds one connection until the end of the file or `close`. Seeking restarts the
/// transfer at the new position with `REST` (spec 11 › Target already exists and resume).
/// Used by one thread at a time; only `close` and `interrupt` may also be called from another
/// thread, to end a read that waits for a server which does not answer. The read then fails,
/// and its thread gives the connection back. After `interrupt` every read and seek fails.
///
/// Used by one thread at a time, as `FileReader` allows; what `close` and `interrupt` touch is
/// guarded by `stateLock` (see there).
private final class FTPReader: FileReader, @unchecked Sendable {
    private let session: FTPSession
    private let path: String
    private let asText: Bool
    private var active: (stream: NetStream, connection: FTPConnection)?
    private var position: UInt64 = 0
    private var atEnd = false
    private var converter = LineEndConverter()
    /// Guards `active` (written under it by the owning thread), `isBusy` and `wasClosed`.
    /// `position`, `atEnd` and the converter belong to the owning thread alone; `close` and
    /// `interrupt`, which may come from another thread, do not touch them.
    private let stateLock = NSLock()
    /// True while a read or a seek of the owning thread is under way.
    private var isBusy = false
    private var wasClosed = false
    /// Set by `interrupt`; the waits of this reader (also for a free connection) look at it.
    private let abort = CancellationFlag()
    /// A short way forward is read and thrown away instead of starting a new transfer.
    private static let skipLimit: UInt64 = 256 * 1_024

    init(session: FTPSession, path: String, asText: Bool) {
        self.session = session
        self.path = path
        self.asText = asText
    }

    deinit {
        // Dropped without `close`: the server is told in the background, not on this thread.
        guard let active else { return }
        let session = session
        Background.run(lane: session) {
            active.connection.abortTransfer()
            session.release(active.connection, transfer: .read)
        }
    }

    private func setActive(_ value: (stream: NetStream, connection: FTPConnection)?) {
        stateLock.lock()
        active = value
        let interrupted = wasClosed || abort.isCancelled
        // Under the lock, like `interrupt`: once `active` is cleared the connection may be another thread's.
        if interrupted { value?.connection.interrupt() }
        stateLock.unlock()
    }

    /// Marks a call of the owning thread as under way; false after `close`.
    private func begin() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !wasClosed else { return false }
        isBusy = true
        return true
    }

    private func end() {
        stateLock.lock()
        isBusy = false
        let closed = wasClosed
        stateLock.unlock()
        // Closed from another thread while this call ran: this thread cleans up.
        if closed { stop() }
    }

    func read(upToCount count: Int) throws -> Data? {
        if abort.isCancelled { throw NetworkError.cancelled }
        guard begin() else { return nil }
        defer { end() }
        while !atEnd {
            if active == nil {
                setActive(try session.beginDownload(path, asText: asText, offset: position, cancellation: abort))
            }
            guard let active else { break }
            do {
                guard
                    let block = try active.stream.read(upToCount: count, timeout: session.timeout, cancellation: abort)
                else {
                    setActive(nil)
                    atEnd = true
                    defer { session.release(active.connection, transfer: .read) }
                    try active.connection.finishTransfer(cancellation: abort)
                    let rest = converter.finishLocal()
                    return rest.isEmpty ? nil : rest
                }
                session.noteProgress()
                position += UInt64(block.count)
                let data = asText ? converter.toLocal(block) : block
                // A block that was only half a line end gives nothing yet.
                if !data.isEmpty { return data }
            } catch {
                stop()
                throw error
            }
        }
        return nil
    }

    func seek(to offset: UInt64) throws {
        if abort.isCancelled { throw NetworkError.cancelled }
        // Like a read, a seek is a call `close` must not run beside: it reads from the
        // connection and changes the position.
        guard begin() else { throw NetworkError.cancelled }
        defer { end() }
        if offset == position, !atEnd { return }
        if asText { throw FileSystemError.notSupported("Continuing a transfer in text mode") }
        if let active, !atEnd, offset > position, offset - position <= Self.skipLimit {
            var left = Int(offset - position)
            do {
                while left > 0 {
                    guard
                        let block = try active.stream.read(
                            upToCount: left, timeout: session.timeout, cancellation: abort)
                    else { break }
                    left -= block.count
                    position += UInt64(block.count)
                }
            } catch {
                stop()
                throw error
            }
            if left == 0 { return }
        }
        stop()
        position = offset
        atEnd = false
    }

    /// Takes the running transfer out of this reader's hands; nil when there is none.
    private func detach() -> (stream: NetStream, connection: FTPConnection)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let running = active
        active = nil
        return running
    }

    /// Ends the running transfer before its end and gives the connection back. Called by the
    /// owning thread; waits for the server's answer to the broken transfer.
    private func stop() {
        guard let running = detach() else { return }
        // A server that is not answering is not asked how the transfer ended.
        if abort.isCancelled { running.connection.abandonTransfer() } else { running.connection.abortTransfer() }
        session.release(running.connection, transfer: .read)
    }

    func interrupt() {
        abort.cancel()
        // Under the lock: a connection that was given back is somebody else's.
        stateLock.lock()
        active?.connection.interrupt()
        stateLock.unlock()
    }

    /// Returns at once, from any thread. A call under way on the owning thread is cut short
    /// and that thread cleans up; otherwise the server is told in the background that the
    /// transfer is over, which may take as long as the server takes to answer.
    func close() {
        stateLock.lock()
        wasClosed = true
        if isBusy {
            // A read is under way on another thread, perhaps waiting for data that never
            // comes: cutting the connection ends it. Decided and done under the lock, as in
            // `interrupt`: the reading thread clears `active` under it before it gives the
            // connection back, so what is cut here is still this reader's.
            active?.connection.interrupt()
            stateLock.unlock()
            return
        }
        let running = active
        active = nil
        stateLock.unlock()
        guard let running else { return }
        let (session, gaveUp) = (session, abort.isCancelled)
        session.noteReturning(1)
        Background.run(lane: session) {
            if gaveUp { running.connection.abandonTransfer() } else { running.connection.abortTransfer() }
            session.release(running.connection, transfer: .read)
            session.noteReturning(-1)
        }
    }
}

/// A file being uploaded (`STOR`, or `APPE` to continue one). Used by one thread; `interrupt` may
/// be called from another thread to end a write that waits for a server which does not answer.
///
/// Used by one thread at a time, as `FileWriter` allows; `interrupt` touches only the flag and
/// the connection, the latter under `holdLock`.
private final class FTPWriter: FileWriter, @unchecked Sendable {
    private let session: FTPSession
    private let path: String
    private let asText: Bool
    private var active: (stream: NetStream, connection: FTPConnection)?
    /// The same connection for `interrupt`, which cannot look at `active`.
    private let connection: FTPConnection
    private var converter = LineEndConverter()
    private var failed = false
    private var written: Int64 = 0
    /// The length the file had when this writer started: 0 for a new file. What is written
    /// follows it, and the length the server reports when the file is closed must be the sum.
    private let start: Int64
    private let abort = CancellationFlag()
    /// Guards `isHolding`: the connection may be cut by `interrupt` only while this writer has it.
    private let holdLock = NSLock()
    private var isHolding = true

    init(session: FTPSession, connection: FTPConnection, stream: NetStream, path: String, asText: Bool, start: Int64) {
        self.session = session
        self.path = path
        self.asText = asText
        self.connection = connection
        self.start = start
        active = (stream, connection)
    }

    deinit {
        // Dropped without `close`: aborting waits for the server, which happens in the background.
        guard let active else { return }
        let session = session
        Background.run(lane: session) {
            active.connection.abortTransfer()
            session.release(active.connection, transfer: .write)
        }
    }

    func write(_ data: Data) throws {
        if abort.isCancelled {
            failed = true
            throw NetworkError.cancelled
        }
        guard let active else { throw NetworkError.connectionLost }
        do {
            try active.stream.write(
                asText ? converter.toNetwork(data) : data, timeout: session.timeout, cancellation: abort)
            written += Int64(data.count)
            session.noteProgress()
        } catch {
            failed = true
            throw error
        }
    }

    func close(attributes: FileAttributes) throws {
        guard let active else { return }
        self.active = nil
        let interrupted = abort.isCancelled
        do {
            if interrupted { throw NetworkError.cancelled }
            if failed { throw NetworkError.connectionLost }
            try active.stream.finishWriting(timeout: session.timeout, cancellation: abort)
        } catch {
            if interrupted { active.connection.abandonTransfer() } else { active.connection.abortTransfer() }
            giveBack(active.connection)
            if failed, !interrupted { return }
            throw error
        }
        defer { giveBack(active.connection) }
        try active.connection.finishTransfer(cancellation: abort)
        // The server said the transfer is complete; what it has is compared with what was
        // sent. A continued file may have kept what lay beyond the new end, or have been
        // started anew (`APPE` taken for `STOR`), and an upload that lost its end can still be
        // answered with a 226. In text mode the server's length is not ours.
        if !asText {
            var length: Int64?
            if active.connection.offers("SIZE") { length = try active.connection.size(of: path, cancellation: abort) }
            if length == nil, active.connection.offers("MLST") {
                length = try active.connection.status(of: path, cancellation: abort).flatMap {
                    $0.isDirectory ? nil : $0.size
                }
            }
            if let length, length != start + written {
                throw NetworkError.unexpected(
                    "the file on the server has \(length) bytes after the upload, not \(start + written)")
            }
        }
        // On the connection the file came through, which is free again.
        session.applyAfterUpload(attributes, to: path, on: active.connection)
    }

    private func giveBack(_ connection: FTPConnection) {
        holdLock.lock()
        isHolding = false
        holdLock.unlock()
        session.release(connection, transfer: .write)
    }

    func interrupt() {
        abort.cancel()
        holdLock.lock()
        if isHolding { connection.interrupt() }
        holdLock.unlock()
    }
}
