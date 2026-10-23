import AFMKernel
import Foundation

/// A connection to an SFTP server (the secure shell's file transfer).
///
/// The system's own `/usr/bin/ssh` makes the connection, so everything the user has set up for it
/// works: keys, the agent, `~/.ssh/config`, known hosts, jump hosts. A password, the passphrase of
/// a key and the question about an unknown host key are asked through `AskpassHelper`.
///
/// **Threading.** Safe from any thread. One `SFTPChannel` serves all threads at once; it is
/// opened on first use and opened again when it broke.
///
/// All mutable state is guarded by `lock`.
internal final class SFTPSession: RemoteSession, @unchecked Sendable {
    /// What one login learns while it answers the questions of ssh.
    private struct LoginAttempt {
        /// The password the user typed for this server's login, if any.
        var typedPassword: String?
        /// Whether the stored password was given to ssh.
        var offeredPassword = false
        /// Whether the user declined to answer a question.
        var refused = false
    }

    /// The largest piece read or written with one request; every server takes this much.
    internal static let blockSize = 32_768
    /// The most requests of a transfer that are under way at the same time.
    ///
    /// With 32 KB each this keeps 2 MB on the way, which is what a fast line with a long delay
    /// needs; a slow line gets fewer (`TransferWindow`).
    internal static let window = 64

    /// Set by `disconnect`: ends the waits of this session that have no flag of their own.
    internal let closing = CancellationFlag()
    /// The names of this server that are written back as they came.
    internal let names = NameMemory()
    /// The program that runs in place of ssh (tests); nil for ssh itself.
    internal let transport: SFTPTransport?
    private let environment: SessionEnvironment
    private let lock = NSLock()
    /// Held while the channel is being opened, so several threads share one login.
    private let connectLock = NSLock()
    private var currentProfile: ConnectionProfile
    private var channel: SFTPChannel?
    /// The channel of a login that is under way, so `disconnect` can end it.
    private var opening: SFTPChannel?
    private var hasConnected = false
    private var isClosed = false
    private var isAsking = false
    private var home = "/"
    private var declined: (error: any Error, at: Date)?
    private var mayConnect = false
    private var stallTime: TimeInterval?

    /// How long a thread waits for another thread's login that makes no progress, nil for the
    /// usual time (see `open`).
    ///
    /// Tests shorten it.
    internal var stallLimit: TimeInterval? {
        get { lock.withLock { stallTime } }
        set { lock.withLock { stallTime = newValue } }
    }

    /// The profile of the server; after a login with a typed password it holds that password.
    internal var profile: ConnectionProfile { lock.withLock { currentProfile } }

    /// True once a login has succeeded, until `disconnect`.
    internal var isConnected: Bool { lock.withLock { hasConnected && !isClosed } }

    /// True while ssh is being started and logs in.
    internal var isConnecting: Bool { lock.withLock { opening != nil && !isClosed } }

    /// Seconds a request waits for its answer, from the preferences.
    internal var timeout: TimeInterval { environment.options.values.timeout }

    /// A session that is not connected yet; `transport` runs another program in place of ssh (tests).
    internal init(profile: ConnectionProfile, environment: SessionEnvironment, transport: SFTPTransport?) {
        currentProfile = profile
        self.environment = environment
        self.transport = transport
    }

    // MARK: Connecting

    /// Connects if necessary and returns the directory the login leads to.
    internal func connect(cancellation: CancellationFlag?) throws -> String {
        _ = try open(cancellation: cancellation)
        return lock.withLock { home }
    }

    /// Returns at once.
    ///
    /// A login that is under way ends with it: its ssh is stopped too.
    internal func disconnect() {
        lock.lock()
        isClosed = true
        let (open, starting) = (channel, opening)
        channel = nil
        lock.unlock()
        closing.cancel()
        open?.close()
        starting?.close()
    }

    /// Runs requests on the channel.
    ///
    /// A channel that was dropped while idle is opened again.
    internal func perform<Result>(cancellation: CancellationFlag?, _ work: (SFTPChannel) throws -> Result)
        throws -> Result
    {
        try work(try open(cancellation: cancellation))
    }

    /// The channel, opened if necessary.
    private func open(cancellation: CancellationFlag?) throws -> SFTPChannel {
        // The usual case takes no lock that a login holds.
        lock.lock()
        if let existing = channel, !existing.isClosed, !isClosed {
            lock.unlock()
            return existing
        }
        lock.unlock()
        try waitForOtherLogins(cancellation: cancellation)
        defer { connectLock.unlock() }
        lock.lock()
        let (existing, closed, recent, asksFirst) = (
            channel, isClosed, declined, currentProfile.asksBeforeConnecting && !mayConnect
        )
        let server = currentProfile
        lock.unlock()
        if closed { throw NetworkError.notConnected(server.key.description) }
        if let existing, !existing.isClosed {
            return existing
        }
        if let recent, Date().timeIntervalSince(recent.at) < environment.declineMemory { throw recent.error }
        if asksFirst {
            guard asking({ environment.askToConnect(server) }) else { throw decline(NetworkError.cancelled) }
            lock.withLock { mayConnect = true }
        }
        return try logIn(server, storedWasRefused: false, cancellation: cancellation)
    }

    /// Takes `connectLock`, which the caller unlocks.
    ///
    /// Another thread may be logging in, perhaps waiting for the user; this one can still be
    /// cancelled, ends with the session, and gives up when the login makes no progress.
    private func waitForOtherLogins(cancellation: CancellationFlag?) throws {
        let began = Date()
        let patience = stallLimit ?? max(60, 2 * timeout) + timeout + 30
        try lockPatiently(connectLock, cancellation: cancellation) {
            self.lock.lock()
            defer { self.lock.unlock() }
            if self.isClosed {
                return NetworkError.notConnected(self.currentProfile.key.description)
            }
            // The time the user takes to answer a question does not count.
            if !self.isAsking, Date().timeIntervalSince(began) > patience {
                return NetworkError.busy("Another login to \(self.currentProfile.key.description) is still under way.")
            }
            return nil
        }
    }

    /// Asks the user something; meanwhile a waiting login does not count the time.
    private func asking<Answer>(_ question: () -> Answer) -> Answer {
        lock.withLock { isAsking = true }
        defer { lock.withLock { isAsking = false } }
        return question()
    }

    /// Remembers that the user said no, so that the next attempts fail without asking again.
    private func decline(_ error: any Error) -> any Error {
        lock.withLock { declined = (error, Date()) }
        return error
    }

    /// Logs in and makes the channel the session's.
    ///
    /// The stored password is tried once. When the server does not take it, the login is
    /// made again and the user is asked; an answer that works takes the stored one's place.
    private func logIn(_ profile: ConnectionProfile, storedWasRefused: Bool, cancellation: CancellationFlag?) throws
        -> SFTPChannel
    {
        var attempt = LoginAttempt()
        do {
            let created = try start(profile, cancellation: cancellation) { helper, question in
                answer(question, with: helper, for: profile, during: &attempt)
            }
            return try adopt(
                created,
                of: profile,
                typedPassword: attempt.typedPassword,
                storedWasRefused: storedWasRefused
            )
        } catch {
            lock.withLock { opening = nil }
            if case NetworkError.loginFailed = error, attempt.offeredPassword, !storedWasRefused, !attempt.refused,
                cancellation?.isCancelled != true
            {
                var withoutPassword = profile
                withoutPassword.password = nil
                return try logIn(withoutPassword, storedWasRefused: true, cancellation: cancellation)
            }
            // Remembered as a refusal only when the user said no to a question.
            throw attempt.refused ? decline(error) : error
        }
    }

    /// Answers one question of ssh: a notice goes to the log, the first request for this server's
    /// password gets the stored one, everything else is asked of the user.
    ///
    /// False when the user gave no answer.
    private func answer(
        _ question: AskpassHelper.Question,
        with helper: AskpassHelper,
        for profile: ConnectionProfile,
        during attempt: inout LoginAttempt
    ) -> Bool {
        let kind = SSHQuestion(question.text)
        if question.kind == .notice {
            // Nothing to answer (touch the security key): said in the log.
            environment.log(question.text)
            helper.reply("", to: question)
            return true
        }
        let isConfirmation = question.kind == .confirm || kind == .hostKey
        let isPassword = Self.asksForPassword(question.text, of: profile)
        if !isConfirmation, !attempt.offeredPassword, isPassword, let password = profile.password {
            // The stored password answers the first request for this server's password.
            attempt.offeredPassword = true
            helper.reply(password, to: question)
            return true
        }
        guard let answer = asking({ environment.askSecret(profile, kind.shown(question.text), !isConfirmation) })
        else {
            attempt.refused = true
            return false
        }
        if isPassword { attempt.typedPassword = answer }
        helper.reply(answer, to: question)
        return true
    }

    /// Makes the channel of a login that succeeded the session's, unless the session was
    /// disconnected meanwhile.
    private func adopt(
        _ created: (channel: SFTPChannel, home: String),
        of profile: ConnectionProfile,
        typedPassword: String?,
        storedWasRefused: Bool
    ) throws -> SFTPChannel {
        environment.log("Logged in to \(profile.key.description), at \(created.home)")
        lock.lock()
        if isClosed {
            // Disconnected while the login ran: the channel is nobody's.
            opening = nil
            lock.unlock()
            created.channel.close()
            throw NetworkError.notConnected(profile.key.description)
        }
        channel = created.channel
        opening = nil
        hasConnected = true
        if created.home.hasPrefix("/") { home = RemotePath.normalized(created.home) }
        if let typedPassword { currentProfile.password = typedPassword }
        lock.unlock()
        // A password typed in place of a stored one that failed is the stored one now.
        if storedWasRefused, let typedPassword { environment.rememberPassword(profile, typedPassword) }
        return created.channel
    }

    /// Starts ssh, answers its questions through `answer`, and returns the channel and the
    /// directory the login leads to.
    private func start(
        _ profile: ConnectionProfile,
        cancellation: CancellationFlag?,
        answer: (AskpassHelper, AskpassHelper.Question) -> Bool
    ) throws -> (channel: SFTPChannel, home: String) {
        let options = environment.options.values
        let (created, askpass) = try makeChannel(for: profile, options: options)
        lock.lock()
        let closed = isClosed
        if !closed { opening = created }
        lock.unlock()
        if closed { throw NetworkError.notConnected(profile.key.description) }
        environment.log("Connect to: \(profile.key.description)")
        do {
            // ssh has its own time limit for reaching the server; ours is for a login that hangs.
            try created.start(timeout: options.timeout + 30, cancellation: cancellation ?? closing) {
                guard let askpass, let question = askpass.pendingQuestion() else {
                    return true
                }
                return answer(askpass, question)
            }
            let packet = try created.request(
                .realpath,
                timeout: options.timeout,
                cancellation: cancellation ?? closing
            ) { $0.string(".") }
            var decoder = try packet.expect(.name)
            _ = try decoder.u32()
            return (created, try decoder.string())
        } catch {
            if case NetworkError.connectionLost = error {
                // ssh ended: what it printed says why (no route, wrong password, host key changed).
                // Its last line may still be on its way when the end is noticed, so it is waited for.
                let said = created.errorMessageAtTheEnd()
                created.close()
                throw NetworkError.loginFailed(said.isEmpty ? "The secure shell ended without a message." : said)
            }
            created.close()
            throw error
        }
    }

    deinit {
        // Nothing to release.
    }
}
