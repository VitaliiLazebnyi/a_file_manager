import AFMKernel
import CryptoKit
import Foundation
import Network
import Security

/// What can go wrong between this program and a server.
public enum NetworkError: LocalizedError {
    case timedOut(String)
    case connectionFailed(String)
    case connectionLost
    case cancelled
    /// The server answered a command with an error.
    case refused(FTPReply)
    case loginFailed(String)
    case untrustedCertificate(CertificateInfo)
    case unexpected(String)
    case notConnected(String)
    /// An FTPS server insists that data connections resume the control connection's TLS
    /// session, which `Network.framework` gives no way to do.
    case sessionReuseRequired(String)
    /// Something was done only in part; the text says what is where now.
    case incomplete(String)
    /// A wait for a connection of the server's pool, or for another thread's login, that ended
    /// because nothing moved for too long.
    case busy(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let what): return "The server did not answer in time (\(what))."
        case .connectionFailed(let why): return "Connect call failed! \(why)"
        case .connectionLost: return "The connection to the server was lost."
        case .cancelled: return "The operation was cancelled."
        case .refused(let reply): return "The server answered: \(reply.message)"
        case .loginFailed(let why): return "Login failed. \(why)"
        case .untrustedCertificate(let info): return "The server's certificate is not trusted: \(info.problem)"
        case .unexpected(let what): return "Unexpected answer from the server: \(what)"
        case .notConnected(let server): return "There is no connection to \(server)."
        case .sessionReuseRequired(let said):
            return
                "The server requires the encrypted data connections to reuse the TLS session of the control connection, "
                + "which this program does not support (the server said: \(said)). "
                + "Turn off \"require session reuse\" on the server (vsftpd: require_ssl_reuse=NO) or use SFTP."
        case .incomplete(let what): return what
        case .busy(let what): return what
        }
    }

    /// True when the connection itself is gone, so the same command may work on a new one.
    var isConnectionLevel: Bool {
        switch self {
        case .connectionLost, .timedOut, .connectionFailed: return true
        case .refused(let reply): return reply.code == 421
        default: return false
        }
    }
}

/// A value one thread waits for and another delivers. Safe from any thread.
final class Pending<Value> {
    private let condition = NSCondition()
    private var value: Value?

    func fulfill(_ value: Value) {
        condition.lock()
        if self.value == nil { self.value = value }
        condition.broadcast()
        condition.unlock()
    }

    /// The value when it is there already; never waits.
    func poll() -> Value? {
        condition.lock()
        defer { condition.unlock() }
        return value
    }

    /// Nil when the time is up. A set cancellation flag ends the wait with `NetworkError.cancelled`.
    func wait(timeout: TimeInterval, cancellation: CancellationFlag? = nil) throws -> Value? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while value == nil {
            if cancellation?.isCancelled == true { throw NetworkError.cancelled }
            let now = Date()
            if now >= deadline { return nil }
            // Woken a few times a second to notice a cancellation.
            condition.wait(until: min(deadline, now.addingTimeInterval(0.1)))
        }
        return value
    }
}

/// What the user is shown of a certificate that could not be verified (spec 11 › Certificates).
public struct CertificateInfo: Equatable {
    /// SHA-256 of the certificate, as `AB:CD:…`.
    public let fingerprint: String
    public let subject: String
    /// Why the system does not trust it.
    public let problem: String
}

/// The certificates the user chose to trust although the system does not, by server.
/// Safe from any thread.
///
/// The certificates trusted for good are not read from the settings, which a file from
/// somebody else can replace: `load` fetches them, on first use, from where only the user's
/// own answers are kept (the Keychain).
public final class CertificateTrust {
    private let lock = NSLock()
    private var accepted: [String: Set<String>]
    private var isLoaded = false
    /// Reads the certificates that were accepted for good. Called once, on the thread that
    /// first connects with TLS, never on the main thread by this module.
    public var load: (() -> [String: [String]])?

    public init(accepted: [String: [String]] = [:]) {
        self.accepted = [:]
        for (host, fingerprints) in accepted { self.accepted[host.lowercased(), default: []].formUnion(fingerprints) }
    }

    /// Fetches the stored certificates if that was not done yet. May take a moment.
    public func prepare() {
        lock.lock()
        let loader = isLoaded ? nil : load
        isLoaded = true
        lock.unlock()
        guard let stored = loader?() else { return }
        lock.lock()
        for (host, fingerprints) in stored { accepted[host.lowercased(), default: []].formUnion(fingerprints) }
        lock.unlock()
    }

    public func isAccepted(_ fingerprint: String, for host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return accepted[host.lowercased()]?.contains(fingerprint) ?? false
    }

    /// The certificates accepted for a server so far, in order.
    public func fingerprints(for host: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return (accepted[host.lowercased()] ?? []).sorted()
    }

    public func accept(_ fingerprint: String, for host: String) {
        lock.lock()
        defer { lock.unlock() }
        accepted[host.lowercased(), default: []].insert(fingerprint)
    }

    /// Makes `fingerprint` the only certificate accepted for the server: the answer to a
    /// certificate that changed. The ones accepted before are no longer trusted.
    public func replace(with fingerprint: String, for host: String) {
        lock.lock()
        defer { lock.unlock() }
        accepted[host.lowercased()] = [fingerprint]
    }
}

/// What a TLS connection needs to know: whose certificate to expect and which exceptions the
/// user made. `rejected` receives the certificate when the handshake fails because of it, so
/// the thread that connects can ask the user and try again.
final class TLSSettings {
    let host: String
    let trust: CertificateTrust
    private let lock = NSLock()
    private var rejectedCertificate: CertificateInfo?
    /// Called where a certificate is checked, before the check; tests make a check slow with it.
    var beforeEvaluating: () -> Void = {}

    init(host: String, trust: CertificateTrust) {
        self.host = host
        self.trust = trust
    }

    var rejected: CertificateInfo? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return rejectedCertificate
        }
        set {
            lock.lock()
            rejectedCertificate = newValue
            lock.unlock()
        }
    }

    /// Where certificates are checked. The check may ask the network (revocation) and take
    /// seconds; on a queue of its own it holds up neither the stream it belongs to nor another.
    private static let verifyQueue = DispatchQueue(
        label: "afm.network.verify", qos: .userInitiated, attributes: .concurrent)

    /// Options for `NWProtocolTLS` that verify the server like the system does, and accept what
    /// the user accepted before.
    func options() -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        if isName { sec_protocol_options_set_tls_server_name(security, host) }
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_set_verify_block(
            security,
            { [self] _, secTrust, complete in
                beforeEvaluating()
                complete(evaluate(sec_trust_copy_ref(secTrust).takeRetainedValue()))
            }, TLSSettings.verifyQueue)
        return options
    }

    /// True when the host is a name; an address in text form has no server name to announce.
    private var isName: Bool { IPv4Address(host) == nil && IPv6Address(host) == nil }

    /// Whether the certificate chain is good for this host: trusted by the system and issued to
    /// the host (a name must match a DNS name of the certificate, an address one of its IP
    /// addresses), or accepted by the user before. A chain that fails is remembered in
    /// `rejected` for the thread that connects, which asks the user.
    func evaluate(_ trust: SecTrust) -> Bool {
        // The host is given in both cases: for an address Security compares the certificate's
        // IP addresses, and without it no name would be checked at all.
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) { return true }
        let problem = error.map { CFErrorCopyDescription($0) as String } ?? "It could not be verified."
        guard let info = CertificateInfo(trust: trust, problem: problem) else { return false }
        if self.trust.isAccepted(info.fingerprint, for: host) { return true }
        rejected = info
        return false
    }
}

extension CertificateInfo {
    /// Describes the server's own certificate, the first of the chain.
    init?(trust: SecTrust, problem: String) {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return nil
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
        self.init(
            fingerprint: digest.map { String(format: "%02X", $0) }.joined(separator: ":"),
            subject: (SecCertificateCopySubjectSummary(leaf) as String?) ?? "", problem: problem)
    }
}

/// What the explicit-TLS start-up of a control connection reports back: the greeting it read,
/// or the reply that refused `AUTH TLS`. Written on the connection's queue, read after the
/// connection is ready or has failed.
final class ExplicitTLSReport {
    private let lock = NSLock()
    private var greetingReply: FTPReply?
    private var refusalReply: FTPReply?

    var greeting: FTPReply? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return greetingReply
        }
        set {
            lock.lock()
            greetingReply = newValue
            lock.unlock()
        }
    }

    var refusal: FTPReply? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return refusalReply
        }
        set {
            lock.lock()
            refusalReply = newValue
            lock.unlock()
        }
    }
}

/// Explicit FTPS (`AUTH TLS`, RFC 4217) for `Network.framework`, whose connections cannot switch
/// to TLS half-way by themselves. This protocol sits on top of TCP, reads the server's
/// greeting, sends `AUTH TLS`, and after the `234` puts TLS underneath itself and steps out of
/// the way; the connection reports ready when the handshake is done.
final class FTPAuthTLSFramer: NWProtocolFramerImplementation {
    static let label = "afm-ftp-auth-tls"
    static let definition = NWProtocolFramer.Definition(implementation: FTPAuthTLSFramer.self)
    static let tlsKey = "tls"
    static let reportKey = "report"

    private var parser = FTPReplyParser()
    private var askedForTLS = false

    init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .willMarkReady }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}

    func handleOutput(
        framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool
    ) {
        try? framer.writeOutputNoCopy(length: messageLength)
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        let report = framer.options[FTPAuthTLSFramer.reportKey] as? ExplicitTLSReport
        while true {
            var line: String?
            // One line at a time, so nothing that follows the last reply is taken away.
            let parsed = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 16384) { buffer, _ in
                guard let buffer, let end = buffer.firstIndex(of: 0x0A) else { return 0 }
                var bytes = Array(buffer[..<end])
                if bytes.last == 0x0D { bytes.removeLast() }
                line = String(decoding: bytes, as: UTF8.self)
                return end + 1
            }
            guard parsed, let line else { return 0 }
            guard let reply = parser.feed(line) else { continue }
            if reply.code == 120 { continue }
            if !askedForTLS {
                guard reply.code == 220 else { return fail(framer, report, reply) }
                report?.greeting = reply
                askedForTLS = true
                framer.writeOutput(data: Data("AUTH TLS\r\n".utf8))
                continue
            }
            guard reply.code == 234, let tls = framer.options[FTPAuthTLSFramer.tlsKey] as? NWProtocolTLS.Options else {
                return fail(framer, report, reply)
            }
            do {
                try framer.prependApplicationProtocol(options: tls)
            } catch {
                return fail(framer, report, reply)
            }
            framer.passThroughInput()
            framer.passThroughOutput()
            framer.markReady()
            return 0
        }
    }

    private func fail(_ framer: NWProtocolFramer.Instance, _ report: ExplicitTLSReport?, _ reply: FTPReply) -> Int {
        report?.refusal = reply
        framer.markFailed(error: .posix(.EPROTO))
        return 0
    }
}

/// A TCP connection, with or without TLS, that is used with blocking calls. The contract of a
/// file-system provider is blocking, and so is FTP: one command, one answer.
///
/// **Threading.** `Network.framework` reports on a private queue; what arrives is collected in
/// a buffer under a lock, and the calling thread waits on it. The methods may be called from
/// any thread, but the callers use one stream from one thread at a time. Waiting never blocks
/// the queue, and a time-out leaves the stream usable.
final class NetStream {
    enum Security {
        case none
        /// TLS from the first byte.
        case tls(TLSSettings)
        /// The FTP greeting and `AUTH TLS` in the clear, then TLS.
        case explicitFTP(TLSSettings, ExplicitTLSReport)
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "afm.network.stream")
    private let condition = NSCondition()
    private var isReady = false
    private var failure: Error?
    /// What arrived and was not read yet starts at `readOffset`; reading moves the offset and
    /// the front is cut off now and then, instead of copying the whole rest on every read.
    private var buffer = Data()
    private var readOffset = 0
    private var atEnd = false
    /// Why the connection stopped receiving, when it was not an orderly end. Thrown once
    /// everything that arrived before has been read.
    private var receiveFailure: Error?
    private var isReceiving = false
    private var isClosed = false
    private var hasFinishedWriting = false
    /// True for TLS from the first byte, as data connections have it.
    let isEncrypted: Bool
    /// More than this is not read ahead of the caller.
    private static let highWater = 1 << 20
    /// Uploads go out in pieces of this size, a few at a time.
    private static let sendPiece = 128 * 1024
    private static let sendsInFlight = 4
    /// The read part of the buffer is cut off once it is this large.
    private static let compactAt = 1 << 20

    init(host: String, port: Int, security: Security = .none) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60
        let parameters: NWParameters
        switch security {
        case .none:
            parameters = NWParameters(tls: nil, tcp: tcp)
            isEncrypted = false
        case .tls(let settings):
            parameters = NWParameters(tls: settings.options(), tcp: tcp)
            isEncrypted = true
        case .explicitFTP(let settings, let report):
            parameters = NWParameters(tls: nil, tcp: tcp)
            isEncrypted = false
            let framer = NWProtocolFramer.Options(definition: FTPAuthTLSFramer.definition)
            framer[FTPAuthTLSFramer.tlsKey] = settings.options()
            framer[FTPAuthTLSFramer.reportKey] = report
            parameters.defaultProtocolStack.applicationProtocols.insert(framer, at: 0)
        }
        let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? .any
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
    }

    /// A connection the server opened to us (active mode).
    init(accepted connection: NWConnection) {
        self.connection = connection
        isEncrypted = false
    }

    deinit {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    /// Starts connecting; `waitUntilReady` tells when it is done.
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            condition.lock()
            switch state {
            case .ready:
                isReady = true
            case .waiting(let error), .failed(let error):
                // "Waiting" is how a refused or unreachable address shows; nobody waits for a
                // server to appear here.
                if failure == nil {
                    failure =
                        isReady
                        ? NetworkError.connectionLost : NetworkError.connectionFailed(error.localizedDescription)
                }
            case .cancelled:
                if failure == nil { failure = NetworkError.connectionLost }
            default:
                break
            }
            condition.broadcast()
            condition.unlock()
            if case .waiting = state { connection.cancel() }
            if case .ready = state { receiveMore() }
        }
        connection.start(queue: queue)
    }

    func waitUntilReady(timeout: TimeInterval, cancellation: CancellationFlag? = nil) throws {
        try wait(timeout: timeout, cancellation: cancellation, for: "connecting") { self.isReady ? () : nil }
    }

    /// The address of this end of the connection, for the PORT command.
    var localAddress: String? {
        guard case .hostPort(let host, _)? = connection.currentPath?.localEndpoint else { return nil }
        let text = "\(host)"
        return text.split(separator: "%").first.map(String.init)
    }

    /// The address of the other end, as the network layer reached it; nil when only a name is known.
    var remoteAddress: String? {
        guard case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint else { return nil }
        switch host {
        case .ipv4, .ipv6: return "\(host)"
        default: return nil
        }
    }

    // MARK: Reading

    /// Keeps one receive call outstanding while there is room in the buffer. Runs on the queue.
    private func receiveMore() {
        condition.lock()
        let wanted = !isReceiving && !atEnd && !isClosed && buffered < NetStream.highWater
        if wanted { isReceiving = true }
        condition.unlock()
        guard wanted else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            condition.lock()
            isReceiving = false
            if let data { buffer.append(data) }
            if let error, receiveFailure == nil {
                receiveFailure = NetworkError.connectionFailed(error.localizedDescription)
            }
            if isComplete || error != nil { atEnd = true }
            condition.broadcast()
            condition.unlock()
            receiveMore()
        }
    }

    /// Bytes that arrived and were not read yet. Called with the lock held.
    private var buffered: Int { buffer.count - readOffset }

    /// Takes `count` bytes off the front. Called with the lock held.
    private func consume(_ count: Int) {
        readOffset += count
        if readOffset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
        } else if readOffset >= NetStream.compactAt {
            buffer.removeSubrange(0..<readOffset)
            readOffset = 0
        }
    }

    /// Waits until `ready` returns a value, the stream fails, the time is up or the caller cancels.
    private func wait<Result>(
        timeout: TimeInterval, cancellation: CancellationFlag?, for what: String, _ ready: () throws -> Result?
    ) throws -> Result {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let result = try ready() { return result }
            if let failure { throw failure }
            if cancellation?.isCancelled == true { throw NetworkError.cancelled }
            let now = Date()
            if now >= deadline { throw NetworkError.timedOut(what) }
            condition.wait(until: min(deadline, now.addingTimeInterval(0.1)))
        }
    }

    /// Asks for more when receiving had stopped for a full buffer. Called after a read made
    /// room, with the lock not held; the queue is only bothered when there is something to do.
    private func resumeReceiving() {
        condition.lock()
        let stopped = !isReceiving && !atEnd && !isClosed && isReady
        condition.unlock()
        if stopped { queue.async { [weak self] in self?.receiveMore() } }
    }

    /// The next bytes, at most `count`; nil when the other side has closed the connection.
    /// A connection that broke instead of ending throws, once what arrived before is read.
    func read(upToCount count: Int, timeout: TimeInterval, cancellation: CancellationFlag? = nil) throws -> Data? {
        let data: Data? = try wait(timeout: timeout, cancellation: cancellation, for: "reading") {
            () throws -> Data?? in
            if self.buffered > 0 {
                let piece = Data(self.buffer[self.readOffset..<self.readOffset + min(count, self.buffered)])
                self.consume(piece.count)
                return .some(piece)
            }
            if let failure = self.receiveFailure { throw failure }
            return self.atEnd ? .some(nil) : nil
        }
        if data != nil { resumeReceiving() }
        return data
    }

    /// The next line without its line end. Throws `connectionLost` when the connection ends
    /// first, and `unexpected` when no line end comes within `limit` bytes: a line of a reply
    /// is short, and the wait for one must not collect whatever a server sends instead.
    func readLine(timeout: TimeInterval, limit: Int = FTPLimits.lineLength, cancellation: CancellationFlag? = nil)
        throws -> Data
    {
        /// How far the buffer was searched already, so no byte is looked at twice.
        var searched = 0
        let line: Data? = try wait(timeout: timeout, cancellation: cancellation, for: "waiting for a reply") {
            () throws -> Data?? in
            let from = self.readOffset + min(searched, self.buffered)
            let until = min(self.buffer.count, self.readOffset + limit + 2)
            if from < until, let end = self.buffer[from..<until].firstIndex(of: 0x0A) {
                var line = self.buffer[self.readOffset..<end]
                if line.last == 0x0D { line = line.dropLast() }
                let result = Data(line)
                self.consume(end + 1 - self.readOffset)
                return .some(result)
            }
            searched = max(searched, until - self.readOffset)
            if self.buffered > limit + 1 { throw NetworkError.unexpected("a reply line of more than \(limit) bytes") }
            if let failure = self.receiveFailure { throw failure }
            return self.atEnd ? .some(nil) : nil
        }
        guard let line else { throw NetworkError.connectionLost }
        resumeReceiving()
        return line
    }

    /// True when something has arrived that was not read yet.
    func hasInput(within timeout: TimeInterval) -> Bool {
        (try? wait(timeout: timeout, cancellation: nil, for: "") { self.buffered == 0 && !self.atEnd ? nil : true })
            ?? false
    }

    // MARK: Writing

    /// Sends `data` in pieces. Every piece has its own time-out, so a big block over a slow
    /// uplink goes through as long as it keeps moving, and a few pieces are under way at a
    /// time to keep the line busy.
    func write(_ data: Data, timeout: TimeInterval, cancellation: CancellationFlag? = nil) throws {
        if data.count <= NetStream.sendPiece {
            return try send(data, isFinal: false, timeout: timeout, cancellation: cancellation)
        }
        var outstanding: [Pending<Bool>] = []
        var offset = data.startIndex
        do {
            while offset < data.endIndex {
                let end = min(offset + NetStream.sendPiece, data.endIndex)
                outstanding.append(submit(data[offset..<end], isFinal: false))
                offset = end
                if outstanding.count >= NetStream.sendsInFlight {
                    try complete(outstanding.removeFirst(), timeout: timeout, cancellation: cancellation)
                }
            }
            for pending in outstanding { try complete(pending, timeout: timeout, cancellation: cancellation) }
        } catch {
            // What was not sent in time will not be sent later, behind the caller's back.
            close()
            throw error
        }
    }

    /// Tells the other side that nothing more will be sent (the end of an upload). Under TLS
    /// nothing is sent here: the framework ends an encrypted stream properly (everything
    /// delivered, then the closing alert) only when the connection is closed, and an end
    /// announced before that makes it drop what is still on its way. Found by test.
    /// True once the caller has declared its data complete.
    var didFinishWriting: Bool {
        condition.lock()
        defer { condition.unlock() }
        return hasFinishedWriting
    }

    func finishWriting(timeout: TimeInterval, cancellation: CancellationFlag? = nil) throws {
        condition.lock()
        let alreadyFinished = hasFinishedWriting
        hasFinishedWriting = true
        condition.unlock()
        if !alreadyFinished, !isEncrypted {
            try send(nil, isFinal: true, timeout: timeout, cancellation: cancellation)
        }
    }

    private func send(_ data: Data?, isFinal: Bool, timeout: TimeInterval, cancellation: CancellationFlag?) throws {
        do {
            try complete(submit(data, isFinal: isFinal), timeout: timeout, cancellation: cancellation)
        } catch {
            // What was not sent in time will not be sent later, behind the caller's back.
            close()
            throw error
        }
    }

    private func submit(_ data: Data?, isFinal: Bool) -> Pending<Bool> {
        let sent = Pending<Bool>()
        connection.send(
            content: data, contentContext: isFinal ? .finalMessage : .defaultMessage, isComplete: true,
            completion: .contentProcessed { error in sent.fulfill(error == nil) })
        return sent
    }

    private func complete(_ sent: Pending<Bool>, timeout: TimeInterval, cancellation: CancellationFlag?) throws {
        guard let succeeded = try sent.wait(timeout: timeout, cancellation: cancellation) else {
            throw NetworkError.timedOut("sending")
        }
        if !succeeded { throw NetworkError.connectionLost }
    }

    func close() {
        condition.lock()
        isClosed = true
        if failure == nil { failure = NetworkError.connectionLost }
        condition.broadcast()
        condition.unlock()
        connection.cancel()
    }
}

/// Waits for the server to open a data connection to us (active mode, spec 11 › Active mode,
/// passive mode and the data connection). Used by one thread.
///
/// Only the server is let in: the listener is bound to the address the control connection
/// uses on this side, and a connection from any address but the control connection's other
/// end is closed and the wait goes on. Whoever else reaches the port in the meantime neither
/// receives an upload nor supplies a download or a listing.
final class DataListener {
    private var listener: NWListener
    private var isBound: Bool
    private let queue = DispatchQueue(label: "afm.network.listener")
    private let accepted = Pending<NWConnection>()
    private let peer: String

    /// The text of an address without what differs between two spellings of the same one: the
    /// zone of a link-local address, and the IPv6 form of an IPv4 address.
    static func comparable(_ address: String) -> String {
        var text = address.lowercased()
        if let zone = text.firstIndex(of: "%") { text = String(text[..<zone]) }
        if text.hasPrefix("::ffff:"), text.contains(".") { text = String(text.dropFirst(7)) }
        return ServerKey.bare(text)
    }

    /// `peer` is the address of the server, `local` the address of this end of the control connection.
    init(peer: String, local: String?) throws {
        self.peer = DataListener.comparable(peer)
        var bound: NWListener?
        if let local {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(local), port: .any)
            bound = try? NWListener(using: parameters)
        }
        isBound = bound != nil
        listener = try bound ?? NWListener(using: .tcp, on: .any)
    }

    deinit { listener.cancel() }

    /// Starts listening and returns the port.
    func start(timeout: TimeInterval) throws -> Int {
        if let port = try begin(timeout: timeout) { return port }
        if isBound {
            // The one address could not be listened on (an address with a zone, say): every
            // address then, with the same check of who connects.
            listener.cancel()
            listener = try NWListener(using: .tcp, on: .any)
            isBound = false
            if let port = try begin(timeout: timeout) { return port }
        }
        throw NetworkError.connectionFailed("No port is available for the server to connect to.")
    }

    private func begin(timeout: TimeInterval) throws -> Int? {
        let started = Pending<Bool>()
        listener.newConnectionHandler = { [accepted, peer] connection in
            guard case .hostPort(let host, _) = connection.endpoint, DataListener.comparable("\(host)") == peer else {
                // Not the server: turned away, and the wait goes on.
                connection.cancel()
                return
            }
            accepted.fulfill(connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: started.fulfill(true)
            case .failed, .cancelled: started.fulfill(false)
            default: break
            }
        }
        listener.start(queue: queue)
        guard try started.wait(timeout: timeout) == true, let port = listener.port else { return nil }
        return Int(port.rawValue)
    }

    func accept(timeout: TimeInterval, cancellation: CancellationFlag?) throws -> NetStream {
        defer { listener.cancel() }
        guard let connection = try accepted.wait(timeout: timeout, cancellation: cancellation) else {
            throw NetworkError.timedOut("waiting for the server's data connection")
        }
        let stream = NetStream(accepted: connection)
        stream.start()
        return stream
    }

    func cancel() { listener.cancel() }
}
