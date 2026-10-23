import AFMKernel
import Foundation

/// Opening and logging in connections, and the questions to the user that a login may need.
extension FTPSession {
    /// One login under way: the profile it logs in with, what the user was asked and answered, and
    /// whether this thread holds `loginLock`.
    internal struct LoginAttempt {
        /// The profile, with the user name and password as far as they are known.
        internal var profile: ConnectionProfile
        /// Work in the background asks the user nothing.
        internal let background: Bool
        /// Ends the waits of the login.
        internal let cancellation: CancellationFlag?
        /// Whether this thread holds `loginLock`.
        internal var holdsLock = false
        /// The user refused something; the session remembers it for a while.
        internal var refused = false
        /// The user asked to keep the password once a login takes it.
        internal var remember = false
        /// Whether the user agreed to send the password without encryption.
        internal var askedUnprotected = false
    }

    /// Where the user name and password of a login come from.
    private enum Login {
        /// The user typed them.
        case typed(Credentials)
        /// Another thread's login was accepted with them meanwhile.
        case another(user: String, password: String?, anonymous: Bool)
    }

    /// Opens and logs in one more connection, asking the user for what is missing: consent to
    /// a server nobody chose, a password, or consent to a certificate the system does not trust.
    ///
    /// `background` work asks nothing and fails instead.
    internal func openConnection(cancellation: CancellationFlag?, background: Bool) throws -> FTPConnection {
        condition.lock()
        let wasFirst = !hasConnected
        let roundsBefore = loginRounds
        var login = LoginAttempt(profile: currentProfile, background: background, cancellation: cancellation)
        condition.unlock()
        defer { if login.holdsLock { loginLock.unlock() } }
        if wasFirst {
            try takeLoginLock(cancellation: cancellation)
            login.holdsLock = true
        }
        try join(&login, roundsBefore: roundsBefore)
        defer {
            condition.lock()
            loggingIn -= 1
            condition.unlock()
        }
        do {
            try askToConnect(&login)
            let user = try firstUser(&login)
            return try logIn(&login, as: user)
        } catch {
            condition.lock()
            loginRounds += 1
            // A login that was merely cancelled says nothing to the threads behind it, and is
            // not a refusal to remember: the next attempt tries again.
            if case NetworkError.cancelled = error, !login.refused { loginFailure = nil } else { loginFailure = error }
            if login.refused { declined = (error, Date()) }
            condition.unlock()
            throw error
        }
    }

    /// Joins the logins under way: fails as the first login did when this thread waited behind it, and as
    /// the user's last refusal while it is remembered; else counts this login and takes the profile as it
    /// is now.
    private func join(_ login: inout LoginAttempt, roundsBefore: Int) throws {
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
        login.profile = currentProfile
        loggingIn += 1
        condition.unlock()
        if login.holdsLock, !isFirst {
            // The login is made; the others no longer wait for this one.
            loginLock.unlock()
            login.holdsLock = false
        }
    }

    /// Asks before connecting to a server nobody chose, unless the user agreed already; also notes
    /// whether the user agreed to an unprotected password before.
    private func askToConnect(_ login: inout LoginAttempt) throws {
        condition.lock()
        let asksFirst = login.profile.asksBeforeConnecting && !mayConnect
        login.askedUnprotected = mayGoUnprotected
        condition.unlock()
        guard asksFirst else {
            return
        }
        let profile = login.profile
        guard try agrees(&login, to: { environment.askToConnect(profile) }) else {
            login.refused = true
            throw NetworkError.cancelled
        }
        condition.lock()
        mayConnect = true
        condition.unlock()
    }

    /// The user name of the first try: the profile's, the anonymous login, or what the user types.
    private func firstUser(_ login: inout LoginAttempt) throws -> String {
        if let known = login.profile.user {
            if login.profile.password == nil, known != "anonymous" {
                return try credentials("", &login)
            }
            return known
        }
        if login.profile.anonymous {
            (login.profile.user, login.profile.password) = ("anonymous", environment.options.values.anonymousPassword)
            return "anonymous"
        }
        return try credentials("", &login)
    }

    /// Logs in as `user`, asking again for a certificate that needs consent and for a password the
    /// server did not take, up to four times.
    private func logIn(_ login: inout LoginAttempt, as firstUser: String) throws -> FTPConnection {
        var user = firstUser
        var attempts = 0
        let opened: FTPConnection
        login: while true {
            attempts += 1
            try askToSendUnprotected(&login)
            let connection = FTPConnection(
                config: config(for: login.profile, user: user),
                trust: environment.trust,
                parts: .init(
                    knownLinks: links,
                    knownNames: names,
                    onActivity: { [weak self] in self?.noteProgress() },
                    log: environment.log,
                    clock: environment.clock
                )
            )
            do {
                try connection.connect(cancellation: login.cancellation ?? closing)
                noteLogin(of: connection, profile: login.profile)
                // Kept only now that the server took it.
                if login.remember, let password = login.profile.password {
                    environment.rememberPassword(login.profile, password)
                }
                startKeepAlive()
                opened = connection
                break login
            } catch NetworkError.untrustedCertificate(let certificate) {
                guard attempts < 4 else { throw NetworkError.untrustedCertificate(certificate) }
                try askToTrust(certificate, &login)
            } catch NetworkError.loginFailed(let message) {
                guard attempts < 4 else { throw NetworkError.loginFailed(message) }
                user = try credentials(message, &login)
            }
        }
        return opened
    }

    /// A password on plain FTP can be read by anyone on the way: the user is asked once before it is sent.
    private func askToSendUnprotected(_ login: inout LoginAttempt) throws {
        let profile = login.profile
        guard profile.tls == .plain, profile.user != "anonymous", profile.password?.isEmpty == false,
            !login.askedUnprotected,
            environment.asksAboutUnprotectedLoopback || !Self.isLoopback(profile.key.host)
        else {
            return
        }
        guard try agrees(&login, to: { environment.askToSendPasswordUnprotected(profile) }) else {
            login.refused = true
            throw NetworkError.cancelled
        }
        login.askedUnprotected = true
        condition.lock()
        mayGoUnprotected = true
        condition.unlock()
    }

    /// Asks the user to trust a certificate the system does not; another thread's answer to the same
    /// certificate is enough.
    private func askToTrust(_ certificate: CertificateInfo, _ login: inout LoginAttempt) throws {
        let (profile, host, hadLock) = (login.profile, login.profile.key.host, login.holdsLock)
        let accepted = try agrees(&login) {
            if !hadLock, environment.trust.isAccepted(certificate.fingerprint, for: host) {
                return true
            }
            let known = environment.trust.fingerprints(for: host)
            if known.isEmpty {
                return environment.askToTrust(profile, certificate)
            }
            // Not the certificate the user accepted for this server: a question of its own.
            return environment.askToTrustChanged(profile, certificate, known)
        }
        guard accepted else {
            login.refused = true
            throw NetworkError.untrustedCertificate(certificate)
        }
    }

    /// What the first successful login learnt of the server, and that the session is connected.
    private func noteLogin(of connection: FTPConnection, profile: ConnectionProfile) {
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
    }

    /// Asks for the user name and password, unless another thread got them meanwhile, and
    /// returns the user name; `message` says why a login failed (empty for the first question).
    private func credentials(_ message: String, _ login: inout LoginAttempt) throws -> String {
        let profile = login.profile
        let tried = (profile.user, profile.password)
        let hadLock = login.holdsLock
        let answer = try ask(&login) { () -> Login? in
            if !hadLock {
                // Waited for another thread's question: its answer, once a login accepted it, is used.
                condition.lock()
                let now = currentProfile
                condition.unlock()
                if let user = now.user, (now.user, now.password) != tried {
                    return .another(user: user, password: now.password, anonymous: now.anonymous)
                }
            }
            return environment.askCredentials(profile, message).map(Login.typed)
        }
        guard let answer else {
            login.refused = true
            throw message.isEmpty ? NetworkError.cancelled : NetworkError.loginFailed(message)
        }
        switch answer {
        case .typed(let typed):
            (login.profile.user, login.profile.password, login.profile.anonymous) = (typed.user, typed.password, false)
            login.remember = typed.remember
            return typed.user

        case .another(let user, let password, let anonymous):
            (login.profile.user, login.profile.password, login.profile.anonymous) = (user, password, anonymous)
            return user
        }
    }

    /// A yes-or-no question to the user on behalf of a login (see `ask`); false is the user's no.
    private func agrees(_ login: inout LoginAttempt, to question: () -> Bool) throws -> Bool {
        try ask(&login) { question() ? () : nil } != nil
    }

    /// Asks the user something on behalf of a login.
    ///
    /// Every question is asked with `loginLock` held, so several threads do not each raise a
    /// dialog; `login.holdsLock` tells whether this thread has it already and is set when it is taken
    /// here. Work in the background asks nothing. Nil is the user's refusal.
    private func ask<Answer>(_ login: inout LoginAttempt, _ question: () -> Answer?) throws -> Answer? {
        if login.background { throw NetworkError.busy("A question to the user is not asked from the background.") }
        if !login.holdsLock {
            try takeLoginLock(cancellation: login.cancellation)
            login.holdsLock = true
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

    /// Waits for `loginLock` while another login moves, and fails when the session is closed or the
    /// other login stalls.
    private func takeLoginLock(cancellation: CancellationFlag?) throws {
        let began = Date()
        try lockPatiently(loginLock, cancellation: cancellation) {
            self.condition.lock()
            defer { self.condition.unlock() }
            if self.isClosed {
                return NetworkError.notConnected(self.currentProfile.key.description)
            }
            return self.stalled(
                since: began,
                "Another login to \(self.currentProfile.key.description) is still under way."
            )
        }
    }

    /// The configuration of one connection for `profile`, logging in as `user`.
    private func config(for profile: ConnectionProfile, user: String) -> FTPServerConfig {
        let options = environment.options.values
        return FTPServerConfig(
            host: profile.key.host,
            port: profile.key.port,
            tls: profile.tls,
            user: user,
            password: profile.password ?? "",
            passive: profile.dataConnection.isPassive(byDefault: options.passiveByDefault),
            encoding: profile.encoding,
            timeout: options.timeout,
            initCommands: profile.initCommands,
            listing: profile.listing
        )
    }
}
