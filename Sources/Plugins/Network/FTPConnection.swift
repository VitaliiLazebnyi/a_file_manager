import AFMKernel
import Foundation

/// How file names travel on the control connection (spec 11 › File-name encoding).
public enum NameEncoding: Int, Codable, CaseIterable {
    /// UTF-8 when the server offers it or the names are valid UTF-8, else Western Latin 1.
    case automatic = 0
    case utf8, windowsLatin1, isoLatin1, windowsLatin2, windowsCyrillic, koi8R, macRoman, dosLatinUS, shiftJIS, gb18030,
        big5, eucKR

    public var title: String {
        switch self {
        case .automatic: return "Auto-Detect (UTF-8 if possible)"
        case .utf8: return "UTF-8"
        case .windowsLatin1: return "Western Latin1 (1252)"
        case .isoLatin1: return "Western ISO 8859-1"
        case .windowsLatin2: return "Eastern Europe (1250)"
        case .windowsCyrillic: return "Cyrillic Windows (1251)"
        case .koi8R: return "Cyrillic KOI8-R (20866)"
        case .macRoman: return "Mac Roman"
        case .dosLatinUS: return "DOS-USA (437)"
        case .shiftJIS: return "Japanese (932)"
        case .gb18030: return "Chinese Main Land (936)"
        case .big5: return "Chinese Taiwan (950)"
        case .eucKR: return "Korean (949)"
        }
    }

    /// Nil for the automatic choice.
    var encoding: String.Encoding? {
        func named(_ encoding: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
        }
        switch self {
        case .automatic: return nil
        case .utf8: return .utf8
        case .windowsLatin1: return .windowsCP1252
        case .isoLatin1: return .isoLatin1
        case .windowsLatin2: return .windowsCP1250
        case .windowsCyrillic: return .windowsCP1251
        case .koi8R: return named(.KOI8_R)
        case .macRoman: return .macOSRoman
        case .dosLatinUS: return named(.dosLatinUS)
        case .shiftJIS: return .shiftJIS
        case .gb18030: return named(.GB_18030_2000)
        case .big5: return named(.big5)
        case .eucKR: return named(.EUC_KR)
        }
    }

    /// The encoding names are written in when nothing else is known of a name.
    var sending: String.Encoding { encoding ?? .utf8 }

    func decode(_ data: Data) -> String { decodeTelling(data).text }

    /// The text of bytes from the server, and the encoding that read them. In the automatic
    /// mode bytes that are not UTF-8 are read as Western Latin 1; `NameMemory` keeps that, so
    /// the name goes back to the server as the bytes it came as.
    func decodeTelling(_ data: Data) -> (text: String, encoding: String.Encoding) {
        if let encoding {
            if let text = String(data: data, encoding: encoding) { return (text, encoding) }
            return (String(decoding: data, as: UTF8.self), .utf8)
        }
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8) }
        if let text = String(data: data, encoding: .windowsCP1252) { return (text, .windowsCP1252) }
        return (String(decoding: data, as: UTF8.self), .utf8)
    }

    /// The bytes of a command. Names are sent the way the Mac writes them when composed
    /// (servers compare bytes), except the names the server itself spelled differently, which
    /// `names` remembers. A character the encoding does not have is an error: written as `?`
    /// it would name another file.
    func encode(_ text: String, names: NameMemory? = nil) throws -> Data {
        func bytes(_ piece: String, as encoding: String.Encoding) throws -> Data {
            guard let data = piece.data(using: encoding, allowLossyConversion: false) else {
                throw FileSystemError.notSupported(
                    "Writing the name \(piece) in the encoding of this server (\(title))")
            }
            return data
        }
        guard let names, !names.isEmpty, text.utf8.contains(0x2F) else {
            return try bytes(text.precomposedStringWithCanonicalMapping, as: sending)
        }
        // A command with a path: the path is absolute, so everything after a slash is a name.
        var result = Data()
        for (index, piece) in Array(text.utf8).split(separator: 0x2F, omittingEmptySubsequences: false).enumerated() {
            if index > 0 { result.append(0x2F) }
            let name = String(decoding: piece, as: UTF8.self)
            if index > 0, let spelled = names.encoding(of: piece) {
                result.append(try bytes(name, as: spelled))
            } else {
                result.append(try bytes(name.precomposedStringWithCanonicalMapping, as: sending))
            }
        }
        return result
    }
}

/// The names of a server that would not reach it again as the bytes they came as, were they
/// written the usual way (composed, in the encoding of the connection): names in decomposed
/// form on a server that compares bytes, and names in another encoding than the one in use.
/// Each is kept, by its exact spelling, with the encoding that read it; a command that names
/// it writes it back unchanged in that encoding. Shared by the connections of a session.
/// Safe from any thread.
final class NameMemory {
    private let lock = NSLock()
    private var spellings: [Data: String.Encoding] = [:]
    private static let capacity = 65_536

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return spellings.isEmpty
    }

    func encoding<Bytes: Sequence>(of name: Bytes) -> String.Encoding? where Bytes.Element == UInt8 {
        let key = Data(name)
        lock.lock()
        defer { lock.unlock() }
        return spellings[key]
    }

    func remember(_ name: String, encoding: String.Encoding) {
        lock.lock()
        defer { lock.unlock() }
        if spellings.count >= Self.capacity { spellings.removeAll() }
        spellings[Data(name.utf8)] = encoding
    }

    /// Whether a name read with `encoding` needs to be remembered for a connection that
    /// writes names composed and in `sending`.
    static func needsRemembering(_ name: String, readAs encoding: String.Encoding, sending: String.Encoding) -> Bool {
        if encoding != sending { return true }
        if name.utf8.allSatisfy({ $0 < 0x80 }) { return false }
        return !name.precomposedStringWithCanonicalMapping.utf8.elementsEqual(name.utf8)
    }
}

/// Everything needed to log in to one FTP server.
public struct FTPServerConfig {
    public var host: String
    public var port: Int
    public var tls: TLSMode
    public var user: String
    public var password: String
    /// Passive: this program opens the data connections. Otherwise the server connects back.
    public var passive: Bool
    public var encoding: NameEncoding
    /// Seconds to wait for an answer or for data.
    public var timeout: TimeInterval
    /// Commands sent after the login (spec 11 › Login sequence, Send Commands).
    public var initCommands: [String]
    /// MLSD for listings: nil uses it when the server offers it, true and false insist
    /// (spec 11 › Listing: MLSD or LIST).
    public var usesMLSD: Bool?

    public init(
        host: String, port: Int = 21, tls: TLSMode = .none, user: String = "anonymous", password: String = "",
        passive: Bool = true, encoding: NameEncoding = .automatic, timeout: TimeInterval = 30,
        initCommands: [String] = [],
        usesMLSD: Bool? = nil
    ) {
        self.host = host
        self.port = port
        self.tls = tls
        self.user = user
        self.password = password
        self.passive = passive
        self.encoding = encoding
        self.timeout = timeout
        self.initCommands = initCommands
        self.usesMLSD = usesMLSD
    }

    /// Splits the *Send Commands* field at `;`; `;;` stands for a semicolon inside a command.
    public static func initCommands(from text: String) -> [String] {
        let marker = "\u{1}"
        return text.replacingOccurrences(of: ";;", with: marker).split(separator: ";")
            .map { $0.replacingOccurrences(of: marker, with: ";").trimmingCharacters(in: .whitespaces) }.filter {
                !$0.isEmpty
            }
    }
}

/// What is known of the links of one server: whether each leads to a directory, by path. Shared
/// by the connections of a session, so that what one found, in the background or while listing,
/// spares the others the question. Safe from any thread.
final class LinkMemory {
    private let lock = NSLock()
    private var kinds: [String: Bool] = [:]
    private static let capacity = 2_048

    func isDirectory(_ path: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return kinds[path]
    }

    func remember(_ path: String, isDirectory: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if kinds.count >= Self.capacity { kinds.removeAll() }
        kinds[path] = isDirectory
    }

    /// After anything changed on the server that may have changed where a link leads.
    func forgetAll() {
        lock.lock()
        defer { lock.unlock() }
        kinds.removeAll()
    }
}

/// One control connection to an FTP server with its data connections: the protocol itself
/// (RFC 959, 2228, 2389, 2428, 3659, 4217), spoken over `NetStream`.
///
/// **Threading.** A connection belongs to one thread at a time; `FTPSession` hands it out and
/// takes it back. Every call blocks until the server has answered or the time is up.
final class FTPConnection {
    let config: FTPServerConfig
    private let trust: CertificateTrust
    private var control: NetStream?
    private var replies = FTPReplyParser()
    private(set) var features: [String: String] = [:]
    private(set) var greeting = ""
    private(set) var system = ""
    /// The directory the login led to.
    private(set) var home = "/"
    private(set) var usesUTF8 = false
    private var encoding: NameEncoding
    private var protectsData = false
    private var extendedPassiveFailed = false
    private var currentType: Character?
    /// Links already found to lead to a directory or not, so a listing seen again is not asked again.
    var knownLinks = LinkMemory()
    /// The names of this server that are written back as they came (see `NameMemory`).
    var knownNames = NameMemory()
    /// Called whenever the server showed a sign of life on this connection, from the thread
    /// that uses it: whoever waits for a connection of the pool waits on while this is called.
    var onActivity: (() -> Void)?
    /// The links (full paths) the last listing left unanswered for lack of time.
    private(set) var unresolvedLinks: [String] = []
    private var workingDirectory: String?
    /// The data connection of the transfer in progress.
    private var data: NetStream?
    private var isBroken = false
    /// True from the moment a command was written until its reply has been read (a 421 means
    /// the server did nothing). When a connection fails in between, nobody knows whether the
    /// command took effect, so a command that must not run twice is not repeated.
    private(set) var commandMayHaveRun = false
    /// Guards the two stream references against `interrupt`, the one call from another thread.
    private let streamsLock = NSLock()
    /// When the connection was last used; the pool reads it while it holds the connection.
    var lastUsed = Date()
    /// Called with every line sent and received, for the log.
    var log: ((String) -> Void)?

    init(config: FTPServerConfig, trust: CertificateTrust) {
        self.config = config
        self.trust = trust
        encoding = config.encoding
    }

    var isUsable: Bool { control != nil && !isBroken && data == nil }
    /// A server that offers MLST also has MLSD (RFC 3659), whether or not it lists it.
    var offersMLSD: Bool { features["MLSD"] != nil || features["MLST"] != nil }
    func offers(_ feature: String) -> Bool { features[feature] != nil }

    // MARK: Login

    /// Connects and logs in (spec 11 › Login sequence). Throws `untrustedCertificate` when the
    /// server's certificate needs the user's consent, and `loginFailed` when the user name or
    /// password is not accepted.
    func connect(cancellation: CancellationFlag? = nil) throws {
        // The certificates the user accepted for good are fetched here, on the connecting thread.
        if config.tls != .none { trust.prepare() }
        let settings = TLSSettings(host: config.host, trust: trust)
        let report = ExplicitTLSReport()
        let security: NetStream.Security
        switch config.tls {
        case .none: security = .none
        case .implicit: security = .tls(settings)
        case .explicit: security = .explicitFTP(settings, report)
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

    private func logIn(explicitGreeting: FTPReply?, cancellation: CancellationFlag?) throws {
        var hello = explicitGreeting
        while hello == nil {
            // 120 announces a delay; the greeting follows.
            let reply = try readReply(cancellation: cancellation)
            if reply.code != 120 { hello = reply }
        }
        guard let hello, hello.code == 220 else {
            throw NetworkError.refused(hello ?? FTPReply(code: 421, lines: ["No greeting"]))
        }
        greeting = hello.text

        if config.tls != .none {
            _ = try send("PBSZ 0", cancellation: cancellation)
            // Without PROT P the data connections would stay unencrypted while the session is
            // shown as secure, so a server that refuses it is not used.
            let protection = try send("PROT P", cancellation: cancellation)
            guard protection.isSuccess else {
                throw NetworkError.unexpected(
                    "The server refused to encrypt its data connections (PROT P: \(protection.message)). "
                        + "The files would travel unprotected, so the connection was not used.")
            }
            protectsData = true
        }
        var reply = try send("USER \(config.user)", shown: "USER \(config.user)", cancellation: cancellation)
        if reply.code == 331 {
            reply = try send("PASS \(config.password)", shown: "PASS ***", cancellation: cancellation)
        }
        if reply.code == 332 {
            throw NetworkError.loginFailed("The server asks for an account (ACCT), which is not supported.")
        }
        guard reply.isSuccess else {
            if reply.code == 421 { throw NetworkError.refused(reply) }
            throw NetworkError.loginFailed(reply.message)
        }

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

    /// Says goodbye when the server still listens, and closes.
    func close() {
        if let control, !isBroken, data == nil {
            try? control.write(Data("QUIT\r\n".utf8), timeout: 2)
        }
        data?.close()
        control?.close()
        setStreams(control: nil, data: nil)
    }

    private func setStreams(control: NetStream?, data: NetStream?) {
        streamsLock.lock()
        self.control = control
        self.data = data
        streamsLock.unlock()
    }

    /// Cuts the connection from another thread (Disconnect while a transfer runs); the thread
    /// that uses it then fails at its next step.
    func interrupt() {
        streamsLock.lock()
        let streams = [control, data]
        streamsLock.unlock()
        streams.forEach { $0?.close() }
    }

    // MARK: Commands

    private func stream() throws -> NetStream {
        guard let control, !isBroken else { throw NetworkError.connectionLost }
        return control
    }

    /// Reads one reply. The time limit is for the whole reply, not for each of its lines, and a
    /// reply has a largest size (`FTPLimits`): a server that never finishes one is given up.
    private func readReply(timeout: TimeInterval? = nil, cancellation: CancellationFlag?) throws -> FTPReply {
        let control = try stream()
        let deadline = Date().addingTimeInterval(timeout ?? config.timeout)
        do {
            var read = 0
            while true {
                let left = deadline.timeIntervalSinceNow
                guard left > 0 else { throw NetworkError.timedOut("waiting for a reply") }
                let line = encoding.decode(try control.readLine(timeout: left, cancellation: cancellation))
                read += 1
                // The log gets the start of a very long reply, not all of it.
                if read <= FTPLimits.replyLines { log?(line) }
                if let reply = replies.feed(line) {
                    onActivity?()
                    return reply
                }
                if read > FTPLimits.replyLinesRead {
                    throw NetworkError.unexpected("a reply of more than \(FTPLimits.replyLinesRead) lines")
                }
            }
        } catch {
            // A reply that did not arrive would be taken for the answer to the next command.
            isBroken = true
            throw error
        }
    }

    /// Sends one command and returns the server's answer, whatever it is.
    @discardableResult
    func send(
        _ command: String, shown: String? = nil, replyWithin: TimeInterval? = nil,
        cancellation: CancellationFlag? = nil
    ) throws -> FTPReply {
        let control = try stream()
        // A line end inside a name would be the start of another command.
        guard !command.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else {
            throw FileSystemError.notSupported("A name with a line break")
        }
        log?(shown ?? command)
        lastUsed = Date()
        commandMayHaveRun = false
        do {
            try control.write(
                try encoding.encode(command, names: knownNames) + Data("\r\n".utf8), timeout: config.timeout,
                cancellation: cancellation)
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
    func perform(_ command: String, cancellation: CancellationFlag? = nil) throws -> FTPReply {
        let reply = try send(command, cancellation: cancellation)
        guard reply.isSuccess else { throw NetworkError.refused(reply) }
        return reply
    }

    /// Checks that the server still answers. A connection that a router dropped silently
    /// does not answer at all, so the wait is short.
    func isAlive(cancellation: CancellationFlag? = nil) -> Bool {
        guard isUsable else { return false }
        return (try? send("NOOP", replyWithin: min(config.timeout, 5), cancellation: cancellation))?.isSuccess ?? false
    }

    func changeDirectory(_ path: String, cancellation: CancellationFlag? = nil) throws {
        let path = RemotePath.normalized(path)
        if workingDirectory == path { return }
        workingDirectory = nil
        try perform("CWD \(path)", cancellation: cancellation)
        workingDirectory = path
    }

    private func setType(_ type: Character, cancellation: CancellationFlag?) throws {
        if currentType == type { return }
        try perform("TYPE \(type)", cancellation: cancellation)
        currentType = type
    }

    // MARK: Simple operations

    func makeDirectory(_ path: String, cancellation: CancellationFlag? = nil) throws {
        knownLinks.forgetAll()
        try perform("MKD \(path)", cancellation: cancellation)
    }
    func removeDirectory(_ path: String, cancellation: CancellationFlag? = nil) throws {
        knownLinks.forgetAll()
        // Some servers refuse to remove the directory they stand in.
        if let current = workingDirectory, current == path || current.hasPrefix(path + "/") {
            try? changeDirectory("/", cancellation: cancellation)
        }
        try perform("RMD \(path)", cancellation: cancellation)
    }
    func deleteFile(_ path: String, cancellation: CancellationFlag? = nil) throws {
        knownLinks.forgetAll()
        try perform("DELE \(path)", cancellation: cancellation)
    }

    func rename(_ source: String, to destination: String, cancellation: CancellationFlag? = nil) throws {
        knownLinks.forgetAll()
        let from = try send("RNFR \(source)", cancellation: cancellation)
        guard from.isIntermediate else { throw NetworkError.refused(from) }
        try perform("RNTO \(destination)", cancellation: cancellation)
        workingDirectory = nil
    }

    /// The size of a file in bytes; nil when the server does not tell (a directory, or no SIZE).
    func size(of path: String, cancellation: CancellationFlag? = nil) throws -> Int64? {
        try setType("I", cancellation: cancellation)
        let reply = try send("SIZE \(path)", cancellation: cancellation)
        return reply.code == 213 ? Int64(reply.text.trimmingCharacters(in: .whitespaces)) : nil
    }

    func modificationTime(of path: String, cancellation: CancellationFlag? = nil) throws -> Date? {
        let reply = try send("MDTM \(path)", cancellation: cancellation)
        return reply.code == 213 ? FTPSyntax.time(reply.text.trimmingCharacters(in: .whitespaces)) : nil
    }

    /// The entry at a path through MLST; nil when nothing is there.
    func status(of path: String, cancellation: CancellationFlag? = nil) throws -> RemoteEntry? {
        let reply = try send("MLST \(path)", cancellation: cancellation)
        guard reply.code == 250 else {
            if reply.code / 100 == 5, reply.code != 550 { throw NetworkError.refused(reply) }
            return nil
        }
        return reply.lines.dropFirst().dropLast().lazy.compactMap(FTPListParser.mlst).first
    }

    /// Sets the time of last change with MFMT, where the server offers it.
    func setModificationTime(_ date: Date, of path: String, cancellation: CancellationFlag? = nil) throws {
        guard offers("MFMT") else { throw FileSystemError.notSupported("Changing the date on this server") }
        try perform("MFMT \(FTPSyntax.timeText(date)) \(path)", cancellation: cancellation)
    }

    func setPermissions(_ permissions: UInt16, of path: String, cancellation: CancellationFlag? = nil) throws {
        try perform("SITE CHMOD \(String(permissions & 0o7777, radix: 8)) \(path)", cancellation: cancellation)
    }

    // MARK: Data connections

    /// Opens the data connection for the next transfer command, without waiting for it: with
    /// TLS the handshake only happens once the server has seen the command.
    private func openData(cancellation: CancellationFlag?) throws -> (stream: NetStream?, listener: DataListener?) {
        let control = try stream()
        let security: NetStream.Security = protectsData ? .tls(TLSSettings(host: config.host, trust: trust)) : .none
        // Encrypted data connections cannot be accepted, so TLS always goes the passive way.
        guard config.passive || protectsData else {
            // Only the machine the control connection reached may open the data connection.
            guard let peer = control.remoteAddress else {
                throw NetworkError.connectionFailed("The address of the server is unknown.")
            }
            guard let address = control.localAddress else {
                throw NetworkError.connectionFailed("The local address is unknown.")
            }
            let listener = try DataListener(peer: peer, local: address)
            let port = try listener.start(timeout: config.timeout)
            if let argument = FTPSyntax.portArgument(host: address, port: port) {
                try perform("PORT \(argument)", cancellation: cancellation)
            } else {
                try perform(
                    "EPRT \(FTPSyntax.extendedPortArgument(host: address, port: port))", cancellation: cancellation)
            }
            return (nil, listener)
        }
        var port: Int?
        if !extendedPassiveFailed {
            let reply = try send("EPSV", cancellation: cancellation)
            port = reply.code == 229 ? FTPSyntax.extendedPassivePort(reply.text) : nil
            if port == nil { extendedPassiveFailed = true }
        }
        if port == nil {
            let reply = try send("PASV", cancellation: cancellation)
            guard reply.code == 227, let endpoint = FTPSyntax.passiveEndpoint(reply.text) else {
                throw NetworkError.refused(reply)
            }
            // The address in the reply is often a private one behind a router; the data
            // connection goes to the host the control connection reached.
            port = endpoint.port
        }
        // The same machine the control connection reached: the name may lead to another one on
        // a second lookup (round-robin DNS, IPv4 against IPv6). It stays the name that the
        // certificate is checked for.
        let stream = NetStream(host: control.remoteAddress ?? config.host, port: port ?? 0, security: security)
        stream.start()
        return (stream, nil)
    }

    /// Starts a transfer: `RETR`, `STOR`, `LIST` and the like. The returned stream carries the
    /// data; `finishTransfer` or `abortTransfer` must follow.
    func beginTransfer(
        _ command: String, type: Character, restartAt offset: UInt64 = 0,
        cancellation: CancellationFlag? = nil
    ) throws -> NetStream {
        guard data == nil else { throw NetworkError.unexpected("A transfer is still running on this connection.") }
        try setType(type, cancellation: cancellation)
        let (stream, listener) = try openData(cancellation: cancellation)
        do {
            if offset > 0 {
                let rest = try send("REST \(offset)", cancellation: cancellation)
                guard rest.isIntermediate else { throw NetworkError.refused(rest) }
            }
            let reply = try send(command, cancellation: cancellation)
            guard reply.isPreliminary else { throw refusal(reply) }
            // From here on the server owes a second reply. Whatever goes wrong before the data
            // connection stands, that reply is read, or the connection is not used again: left
            // unread, it would be taken for the answer to the next command.
            var channel: NetStream?
            do {
                channel = try stream ?? listener?.accept(timeout: config.timeout, cancellation: cancellation)
                guard let channel else { throw NetworkError.connectionFailed("No data connection.") }
                try channel.waitUntilReady(timeout: config.timeout, cancellation: cancellation)
                setStreams(control: control, data: channel)
                return channel
            } catch {
                // The command is under way; the server ends it when the data connection fails.
                channel?.close()
                listener?.cancel()
                // A server that wants the control connection's TLS session reused says so here.
                if cancellation?.isCancelled != true,
                    let said = try? readReply(timeout: min(config.timeout, 5), cancellation: cancellation),
                    !said.isPreliminary
                {
                    throw refusal(said, otherwise: error)
                }
                isBroken = true
                throw error
            }
        } catch {
            stream?.close()
            listener?.cancel()
            throw error
        }
    }

    /// The error for a reply that refused a command; a server that insists on TLS session reuse
    /// on the data connections gets its own, so the user is told what is wrong.
    private func refusal(_ reply: FTPReply, otherwise: Error? = nil) -> Error {
        if protectsData, Self.requiresSessionReuse(reply) {
            return NetworkError.sessionReuseRequired(reply.message)
        }
        return otherwise ?? NetworkError.refused(reply)
    }

    /// Whether the reply is a server's complaint that a data connection did not resume the TLS
    /// session of the control connection (vsftpd `require_ssl_reuse`, ProFTPD, FileZilla Server).
    static func requiresSessionReuse(_ reply: FTPReply) -> Bool {
        guard [421, 425, 426, 450, 522, 522, 550].contains(reply.code) else { return false }
        let text = reply.text.lowercased()
        let mentionsSession = text.contains("session") || text.contains("reuse") || text.contains("re-use")
        let says =
            text.contains("reuse") || text.contains("re-use") || text.contains("resum") || text.contains("cached")
            || text.contains("same")
        return mentionsSession && says
    }

    /// Ends a transfer whose data went through completely, and reads the server's verdict.
    func finishTransfer(cancellation: CancellationFlag? = nil) throws {
        guard let channel = data else { return }
        // After a plain upload the end was already announced, and the data connection stays
        // open until the server has confirmed the file. An encrypted one announces its end
        // by closing (see `NetStream.finishWriting`).
        let isUpload = channel.didFinishWriting && !channel.isEncrypted
        if !isUpload { channel.close() }
        defer { channel.close() }
        setStreams(control: control, data: nil)
        var reply = try readReply(cancellation: cancellation)
        // Some servers announce the transfer twice (`125`, then `150`); the verdict is the
        // first reply that is not another announcement.
        var announcements = 0
        while reply.isPreliminary {
            announcements += 1
            guard announcements <= 4 else {
                isBroken = true
                throw NetworkError.unexpected(reply.message)
            }
            reply = try readReply(cancellation: cancellation)
        }
        lastUsed = Date()
        guard reply.isSuccess else { throw refusal(reply) }
    }

    /// Drops a transfer without asking the server about it, for a server that is not answering:
    /// the connection cannot be used again.
    func abandonTransfer() {
        guard let channel = data else { return }
        channel.close()
        setStreams(control: control, data: nil)
        isBroken = true
    }

    /// Ends a transfer early. The server answers the broken data connection with one reply
    /// (426 or 226); when it does not, the connection is not used again.
    func abortTransfer() {
        guard let channel = data else { return }
        channel.close()
        setStreams(control: control, data: nil)
        guard !isBroken, let control else { return }
        if (try? readReply(timeout: min(config.timeout, 10), cancellation: nil)) == nil {
            isBroken = true
            return
        }
        // A server that also confirms the abort sends a second reply right away. One that keeps
        // sending replies is not listened to for long.
        var extra = 0
        while control.hasInput(within: 0.05) {
            extra += 1
            if extra > 3 || (try? readReply(timeout: 2, cancellation: nil)) == nil {
                isBroken = true
                return
            }
        }
        lastUsed = Date()
    }

    // MARK: Listing

    /// Reads a directory: with MLSD where the server offers it, else with LIST (`-la` when
    /// hidden files are wanted). `receive` gets the entries piece by piece and returns false
    /// to stop.
    func list(
        _ path: String, showHidden: Bool, cancellation: CancellationFlag? = nil, receive: ([RemoteEntry]) -> Bool
    ) throws {
        let path = RemotePath.normalized(path)
        unresolvedLinks = []
        var asMLSD = config.usesMLSD ?? offersMLSD
        var channel: NetStream?
        if asMLSD {
            do {
                channel = try beginTransfer("MLSD \(path)", type: "I", cancellation: cancellation)
            } catch NetworkError.refused(let reply)
                where config.usesMLSD == nil && [500, 502, 504].contains(reply.code)
            {
                // Announced but not there: LIST from now on.
                features["MLSD"] = nil
                features["MLST"] = nil
                asMLSD = false
            }
        }
        if !asMLSD {
            // LIST with a path trips over names with spaces and leading dashes on many servers.
            try changeDirectory(path, cancellation: cancellation)
            channel = try beginTransfer(showHidden ? "LIST -la" : "LIST", type: "A", cancellation: cancellation)
        }
        guard let channel else { throw NetworkError.connectionLost }
        // Links are held back: whether one leads to a directory is asked when the listing is through.
        var links: [RemoteEntry] = []
        var splitter = LineSplitter()
        var wanted = true
        var (entriesSoFar, bytesSoFar) = (0, Int64(0))
        let sending = encoding.sending
        func deliver(_ lines: [Data]) {
            // Lines that were read in another encoding than names are written in, apart.
            var foreign: [(text: String, encoding: String.Encoding)] = []
            let texts = lines.map { line -> String in
                let read = encoding.decodeTelling(line)
                if read.encoding != sending { foreign.append(read) }
                return read.text
            }
            let entries = FTPListParser.entries(of: texts, asMLSD: asMLSD)
            for entry in entries where NameMemory.needsRemembering(entry.name, readAs: sending, sending: sending) {
                knownNames.remember(entry.name, encoding: sending)
            }
            for line in foreign {
                if let entry = asMLSD ? FTPListParser.mlsd(line.text) : FTPListParser.list(line.text) {
                    knownNames.remember(entry.name, encoding: line.encoding)
                }
            }
            entriesSoFar += entries.count
            links += entries.filter(\.isSymlink)
            let plain = entries.filter { !$0.isSymlink }
            if !plain.isEmpty { wanted = receive(plain) }
        }
        do {
            while wanted,
                let block = try channel.read(
                    upToCount: 256 * 1_024, timeout: config.timeout, cancellation: cancellation)
            {
                onActivity?()
                bytesSoFar += Int64(block.count)
                guard bytesSoFar <= FTPLimits.listingBytes, entriesSoFar <= FTPLimits.listingEntries else {
                    throw NetworkError.unexpected(
                        "a directory listing of more than \(FTPLimits.listingEntries) entries or \(FTPLimits.listingBytes >> 20) MB"
                    )
                }
                deliver(splitter.feed(block))
            }
        } catch {
            if cancellation?.isCancelled == true { abandonTransfer() } else { abortTransfer() }
            throw error
        }
        guard wanted else {
            cancellation?.isCancelled == true ? abandonTransfer() : abortTransfer()
            return
        }
        if let rest = splitter.finish() { deliver([rest]) }
        if splitter.dropped > 0 {
            log?(
                "\(splitter.dropped) lines of the listing were longer than \(FTPLimits.lineLength) bytes and were left out."
            )
        }
        try finishTransfer(cancellation: cancellation)
        guard wanted, !links.isEmpty, cancellation?.isCancelled != true else { return }
        _ = receive(resolveLinks(links, in: path, cancellation: cancellation))
    }

    /// Whether a link leads to a directory is not in a LIST; each answer costs a round trip, so
    /// what the target's spelling or an earlier question settles is not asked, MLST is used where
    /// the server has it (it does not move the working directory), and a long list of links
    /// is only asked through for a short while.
    private func resolveLinks(_ links: [RemoteEntry], in path: String, cancellation: CancellationFlag?) -> [RemoteEntry]
    {
        let deadline = Date().addingTimeInterval(Self.linkBudget)
        var asked = 0
        return links.map { link in
            var link = link
            let full = RemotePath.join(path, link.name)
            if let known = knownLinks.isDirectory(full) {
                link.isDirectory = known
            } else if link.linkTarget?.hasSuffix("/") == true {
                link.isDirectory = true
            } else if asked < Self.resolvedLinks, Date() < deadline, isUsable,
                cancellation?.isCancelled != true
            {
                asked += 1
                if let isDirectory = probeLink(full, cancellation: cancellation) {
                    link.isDirectory = isDirectory
                    knownLinks.remember(full, isDirectory: isDirectory)
                }
            } else {
                unresolvedLinks.append(full)
            }
            return link
        }
    }

    /// Whether the link at `full` leads to a directory; nil when the connection broke meanwhile.
    func probeLink(_ full: String, cancellation: CancellationFlag? = nil) -> Bool? {
        var isDirectory = false
        if offers("MLST"), let target = try? status(of: full, cancellation: cancellation), !target.isSymlink {
            isDirectory = target.isDirectory
        } else if isUsable {
            isDirectory = (try? changeDirectory(full, cancellation: cancellation)) != nil
        }
        return isUsable ? isDirectory : nil
    }

    private static let resolvedLinks = 32
    private static let linkBudget: TimeInterval = 1.5
    private static let rememberedLinks = 2_048
}
