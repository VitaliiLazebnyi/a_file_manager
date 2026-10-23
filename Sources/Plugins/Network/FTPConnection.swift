import AFMKernel
internal import Foundation

/// One control connection to an FTP server with its data connections: the protocol itself
/// (RFC 959, 2228, 2389, 2428, 3659, 4217), spoken over `NetStream`.
///
/// **Threading.** A connection belongs to one thread at a time; `FTPSession` hands it out and
/// takes it back. Every call blocks until the server has answered or the time is up.
/// `interrupt`, the one call from another thread, touches only the two streams, under `streamsLock`.
/// The state below that the extensions of other files use is internal for them; nothing outside this
/// type touches it.
internal final class FTPConnection: @unchecked Sendable {
    /// How many links of one listing are asked about at most.
    internal static let resolvedLinks = 32
    /// How long the links of one listing are asked about at most, in seconds.
    internal static let linkBudget: TimeInterval = 1.5

    /// The server and how to log in to it.
    internal let config: FTPServerConfig
    /// The certificates accepted for this server, checked on every TLS connection.
    internal let trust: CertificateTrust
    /// The control connection while it stands; set only through `setStreams`.
    internal private(set) var control: NetStream?
    private var replies = FTPReplyParser()
    /// The features in the reply to FEAT, by upper-case name (see `FTPSyntax.features`).
    internal var features: [String: String] = [:]
    /// The text of the server's greeting.
    internal private(set) var greeting = ""
    /// The reply to SYST, empty when the server did not answer it.
    internal private(set) var system = ""
    /// The directory the login led to.
    internal private(set) var home = "/"
    /// Whether the server agreed to names in UTF-8 (OPTS UTF8 ON, or UTF8 among its features).
    internal private(set) var usesUTF8 = false
    /// How names are written: the configured choice, UTF-8 once the server agreed to it.
    internal private(set) var encoding: NameEncoding
    /// Whether the data connections are encrypted (PROT P was accepted).
    internal private(set) var protectsData = false
    /// Whether EPSV failed once, so PASV is used from then on.
    internal var extendedPassiveFailed = false
    private var currentType: Character?
    /// Links already found to lead to a directory or not, so a listing seen again is not asked again.
    internal let knownLinks: LinkMemory
    /// The names of this server that are written back as they came (see `NameMemory`).
    internal let knownNames: NameMemory
    /// Called whenever the server showed a sign of life on this connection, from the thread
    /// that uses it: whoever waits for a connection of the pool waits on while this is called.
    internal let onActivity: (@Sendable () -> Void)?
    /// The links (full paths) the last listing left unanswered for lack of time.
    internal var unresolvedLinks: [String] = []
    /// The directory the server stands in, when it is known.
    internal var workingDirectory: String?
    /// The data connection of the transfer in progress; set only through `setStreams`.
    internal private(set) var data: NetStream?
    /// Whether the connection can no longer be trusted to be in step with the server.
    internal var isBroken = false
    /// True from the moment a command was written until its reply has been read (a 421 means
    /// the server did nothing).
    ///
    /// When a connection fails in between, nobody knows whether the command took effect, so a
    /// command that must not run twice is not repeated.
    internal private(set) var commandMayHaveRun = false
    /// Guards the two stream references against `interrupt`, the one call from another thread.
    private let streamsLock = NSLock()
    /// When the connection was last used, by `clock`; the pool reads it while it holds the connection.
    internal var lastUsed: Date
    /// The time now; a test may give its own clock.
    internal let clock: @Sendable () -> Date
    /// Called with every line sent and received, for the log.
    internal let log: (@Sendable (String) -> Void)?

    /// Whether the connection stands and is free for the next command.
    internal var isUsable: Bool { control != nil && !isBroken && data == nil }
    /// A server that offers MLST also has MLSD (RFC 3659), whether or not it lists it.
    internal var offersMLSD: Bool { features["MLSD"] != nil || features["MLST"] != nil }

    /// A connection that is not connected yet.
    ///
    /// `knownLinks` and `knownNames` are the session's, shared by its connections.
    internal init(config: FTPServerConfig, trust: CertificateTrust, parts: Parts) {
        self.config = config
        self.trust = trust
        knownLinks = parts.knownLinks
        knownNames = parts.knownNames
        onActivity = parts.onActivity
        log = parts.log
        clock = parts.clock
        lastUsed = parts.clock()
        encoding = config.encoding
    }

    /// Whether the server listed a feature (by upper-case name) in its reply to FEAT.
    internal func offers(_ feature: String) -> Bool { features[feature] != nil }

    // MARK: Login

    /// Connects and logs in (spec 11 › Login sequence).
    ///
    /// Throws `untrustedCertificate` when the server's certificate needs the user's consent, and
    /// `loginFailed` when the user name or password is not accepted.
    internal func connect(cancellation: CancellationFlag?) throws {
        // The certificates the user accepted for good are fetched here, on the connecting thread.
        if config.tls != .plain { trust.prepare() }
        let settings = TLSSettings(host: config.host, trust: trust)
        let report = ExplicitTLSReport()
        let security: NetStream.Security
        switch config.tls {
        case .plain:
            security = .plain

        case .implicit:
            security = .tls(settings)

        case .explicit:
            security = .explicitFTP(settings, report)
        }
        let stream = NetStream(host: config.host, port: config.port, security: security)
        log?("Connect to: \(config.host):\(config.port)")
        stream.start()
        do {
            try stream.waitUntilReady(timeout: config.timeout, cancellation: cancellation)
        } catch {
            stream.close()
            if let certificate = settings.rejected { throw NetworkError.untrustedCertificate(certificate) }
            if let refusal = report.refusal { throw NetworkError.refused(refusal) }
            throw error
        }
        setStreams(control: stream, data: nil)
        do {
            try logIn(explicitGreeting: report.greeting, cancellation: cancellation)
        } catch {
            close()
            throw error
        }
    }

    /// Says goodbye when the server still listens, and closes.
    internal func close() {
        if let control, !isBroken, data == nil {
            try? control.write(Data("QUIT\r\n".utf8), timeout: 2, cancellation: nil)
        }
        data?.close()
        control?.close()
        setStreams(control: nil, data: nil)
    }

    /// Sets both stream references under `streamsLock`, so `interrupt` sees them whole.
    internal func setStreams(control: NetStream?, data: NetStream?) {
        streamsLock.lock()
        self.control = control
        self.data = data
        streamsLock.unlock()
    }

    /// Cuts the connection from another thread (Disconnect while a transfer runs); the thread
    /// that uses it then fails at its next step.
    internal func interrupt() {
        streamsLock.lock()
        let streams = [control, data]
        streamsLock.unlock()
        for stream in streams {
            stream?.close()
        }
    }

    // MARK: Commands

    /// Reads one reply, waiting `timeout` seconds at most for all of it.
    ///
    /// The time limit is for the whole reply, not for each of its lines, and a reply has a largest
    /// size (`FTPLimits`): a server that never finishes one is given up.
    internal func readReply(timeout: TimeInterval, cancellation: CancellationFlag?) throws -> FTPReply {
        let controlStream = try stream()
        let deadline = Date().addingTimeInterval(timeout)
        do {
            var reply: FTPReply?
            for read in 1...FTPLimits.replyLinesRead + 1 {
                let left = deadline.timeIntervalSinceNow
                guard left > 0 else { throw NetworkError.timedOut("waiting for a reply") }
                let line = encoding.decode(
                    try controlStream.readLine(timeout: left, limit: FTPLimits.lineLength, cancellation: cancellation)
                )
                // The log gets the start of a very long reply, not all of it.
                if read <= FTPLimits.replyLines { log?(line) }
                reply = replies.feed(line)
                if reply != nil { break }
            }
            guard let reply else {
                throw NetworkError.unexpected("a reply of more than \(FTPLimits.replyLinesRead) lines")
            }
            onActivity?()
            return reply
        } catch {
            // A reply that did not arrive would be taken for the answer to the next command.
            isBroken = true
            throw error
        }
    }

    /// Sends one command and returns the server's answer, whatever it is.
    @discardableResult
    internal func send(_ command: String, cancellation: CancellationFlag?) throws -> FTPReply {
        try send(command, shown: command, replyWithin: config.timeout, cancellation: cancellation)
    }

    /// Sends one command, logged as `shown` (a password is not), and returns the server's answer, whatever it
    /// is, which must arrive within `replyWithin` seconds.
    @discardableResult
    internal func send(
        _ command: String,
        shown: String,
        replyWithin: TimeInterval,
        cancellation: CancellationFlag?
    ) throws -> FTPReply {
        let controlStream = try stream()
        // A line end inside a name would be the start of another command.
        guard !command.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else {
            throw FileSystemError.notSupported("A name with a line break")
        }
        log?(shown)
        lastUsed = clock()
        commandMayHaveRun = false
        do {
            try controlStream.write(
                try encoding.encode(command, names: knownNames) + Data("\r\n".utf8),
                timeout: config.timeout,
                cancellation: cancellation
            )
        } catch let error as FileSystemError {
            // Nothing was sent; the connection is as good as before.
            throw error
        } catch {
            isBroken = true
            throw error
        }
        commandMayHaveRun = true
        let reply = try readReply(timeout: replyWithin, cancellation: cancellation)
        commandMayHaveRun = false
        if reply.code == 421 { isBroken = true }
        return reply
    }

    /// Sends a command that must succeed; any other answer is thrown as `NetworkError.refused`.
    @discardableResult
    internal func perform(_ command: String, cancellation: CancellationFlag?) throws -> FTPReply {
        let reply = try send(command, cancellation: cancellation)
        guard reply.isSuccess else { throw NetworkError.refused(reply) }
        return reply
    }

    /// Sets the transfer type (`A` for text, `I` for bytes), unless it is set already.
    internal func setType(_ type: Character, cancellation: CancellationFlag?) throws {
        if currentType == type {
            return
        }
        try perform("TYPE \(type)", cancellation: cancellation)
        currentType = type
    }

    /// The control connection, when it stands and can be trusted.
    internal func stream() throws -> NetStream {
        guard let control, !isBroken else { throw NetworkError.connectionLost }
        return control
    }

    /// The login sequence on a connection that stands: greeting, encryption of the data, user and
    /// password, then what the server offers.
    private func logIn(explicitGreeting: FTPReply?, cancellation: CancellationFlag?) throws {
        var hello: FTPReply
        if let explicitGreeting {
            hello = explicitGreeting
        } else {
            // 120 announces a delay; the greeting follows.
            repeat {
                hello = try readReply(timeout: config.timeout, cancellation: cancellation)
            } while hello.code == 120
        }
        guard hello.code == 220 else { throw NetworkError.refused(hello) }
        greeting = hello.text
        if config.tls != .plain {
            try protectDataConnections(cancellation: cancellation)
        }
        try authenticate(cancellation: cancellation)
        try learnServer(cancellation: cancellation)
    }

    /// PBSZ and PROT P, on an encrypted control connection.
    private func protectDataConnections(cancellation: CancellationFlag?) throws {
        _ = try send("PBSZ 0", cancellation: cancellation)
        // Without PROT P the data connections would stay unencrypted while the session is
        // shown as secure, so a server that refuses it is not used.
        let protection = try send("PROT P", cancellation: cancellation)
        guard protection.isSuccess else {
            throw NetworkError.unexpected(
                "The server refused to encrypt its data connections (PROT P: \(protection.message)). "
                    + "The files would travel unprotected, so the connection was not used."
            )
        }
        protectsData = true
    }

    /// USER and PASS; the password never reaches the log.
    private func authenticate(cancellation: CancellationFlag?) throws {
        var reply = try send("USER \(config.user)", cancellation: cancellation)
        if reply.code == 331 {
            reply = try send(
                "PASS \(config.password)",
                shown: "PASS ***",
                replyWithin: config.timeout,
                cancellation: cancellation
            )
        }
        if reply.code == 332 {
            throw NetworkError.loginFailed("The server asks for an account (ACCT), which is not supported.")
        }
        guard reply.isSuccess else {
            if reply.code == 421 { throw NetworkError.refused(reply) }
            throw NetworkError.loginFailed(reply.message)
        }
    }

    /// After the login: the features, UTF-8 names, the system, the user's own commands, and the home
    /// directory.
    private func learnServer(cancellation: CancellationFlag?) throws {
        let feat = try send("FEAT", cancellation: cancellation)
        if feat.code == 211 { features = FTPSyntax.features(feat) }
        if encoding == .automatic || encoding == .utf8 {
            let utf8 = try send("OPTS UTF8 ON", cancellation: cancellation)
            usesUTF8 = utf8.isSuccess || features["UTF8"] != nil
            if usesUTF8 { encoding = .utf8 }
        }
        let syst = try send("SYST", cancellation: cancellation)
        if syst.isSuccess { system = syst.text }
        for command in config.initCommands {
            _ = try send(command, cancellation: cancellation)
        }
        let pwd = try send("PWD", cancellation: cancellation)
        if pwd.isSuccess, let path = FTPSyntax.quotedPath(pwd.text), path.hasPrefix("/") {
            home = RemotePath.normalized(path)
        }
        workingDirectory = home
    }

    deinit {
        // Nothing to release: the owner closes the connection.
    }
}
