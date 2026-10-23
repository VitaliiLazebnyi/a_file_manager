import AFMKernel
import Foundation
import Network

/// A TCP connection, with or without TLS, that is used with blocking calls.
///
/// The contract of a file-system provider is blocking, and so is FTP: one command, one answer.
///
/// **Threading.** `Network.framework` reports on a private queue; what arrives is collected in
/// a buffer under a lock, and the calling thread waits on it. The methods may be called from
/// any thread, but the callers use one stream from one thread at a time. Waiting never blocks
/// the queue, and a time-out leaves the stream usable.
///
/// All mutable state is guarded by `condition`; the connection and the queue are safe from any
/// thread.
internal final class NetStream: @unchecked Sendable {
    /// Whether and how the stream is encrypted.
    internal enum Security {
        /// The FTP greeting and `AUTH TLS` in the clear, then TLS.
        case explicitFTP(TLSSettings, ExplicitTLSReport)
        /// No encryption.
        case plain
        /// TLS from the first byte.
        case tls(TLSSettings)
    }

    /// More than this is not read ahead of the caller.
    private static let highWater = 1 << 20
    /// The read part of the buffer is cut off once it is this large.
    private static let compactAt = 1 << 20

    /// True for TLS from the first byte, as data connections have it.
    internal let isEncrypted: Bool
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "afm.network.stream")
    private let condition = NSCondition()
    private var isReady = false
    private var failure: any Error?
    /// What arrived and was not read yet starts at `readOffset`; reading moves the offset and
    /// the front is cut off now and then, instead of copying the whole rest on every read.
    private var buffer = Data()
    private var readOffset = 0
    private var atEnd = false
    /// Why the connection stopped receiving, when it was not an orderly end.
    ///
    /// Thrown once everything that arrived before has been read.
    private var receiveFailure: any Error?
    private var isReceiving = false
    private var isClosed = false
    private var hasFinishedWriting = false

    /// The address of this end of the connection, for the PORT command; nil once the stream is closed.
    internal var localAddress: String? {
        guard !wasClosed, case .hostPort(let host, _)? = connection.currentPath?.localEndpoint else {
            return nil
        }
        let text = "\(host)"
        return text.split(separator: "%").first.map(String.init)
    }

    /// The address of the other end, as the network layer reached it; nil when only a name is known, and
    /// once the stream is closed.
    internal var remoteAddress: String? {
        guard !wasClosed else {
            return nil
        }
        switch connection.currentPath?.remoteEndpoint {
        case .hostPort(.ipv4(let address), _):
            return "\(address)"

        case .hostPort(.ipv6(let address), _):
            return "\(address)"

        default:
            return nil
        }
    }

    /// Tells the other side that nothing more will be sent (the end of an upload).
    ///
    /// Under TLS nothing is sent here: the framework ends an encrypted stream properly (everything
    /// delivered, then the closing alert) only when the connection is closed, and an end announced
    /// before that makes it drop what is still on its way. Found by test. True once the caller has
    /// declared its data complete.
    internal var didFinishWriting: Bool {
        condition.lock()
        defer { condition.unlock() }
        return hasFinishedWriting
    }

    /// Whether `close` was called; the network layer lets go of the connection later, on its queue.
    private var wasClosed: Bool {
        condition.lock()
        defer { condition.unlock() }
        return isClosed
    }

    /// Bytes that arrived and were not read yet.
    ///
    /// Called with the lock held.
    private var buffered: Int { buffer.count - readOffset }

    /// A stream to `host` and `port`, not started yet.
    internal init(host: String, port: Int, security: Security) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60
        let parameters: NWParameters
        switch security {
        case .plain:
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
        // Every 16-bit number is a port (0 is "any"), so a port always comes out.
        // swiftlint:disable:next force_unwrapping
        let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port))!
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
    }

    /// A connection the server opened to us (active mode).
    internal init(accepted connection: NWConnection) {
        self.connection = connection
        isEncrypted = false
    }

    /// Starts connecting; `waitUntilReady` tells when it is done.
    internal func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else {
                return
            }
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

            default:
                // `cancelled` comes only after `close`, or after `waiting` above, which set the failure.
                break
            }
            condition.broadcast()
            condition.unlock()
            if case .waiting = state { connection.cancel() }
            if case .ready = state { receiveMore() }
        }
        connection.start(queue: queue)
    }

    /// Waits until the connection is made (and the TLS handshake done); throws why it was not.
    internal func waitUntilReady(timeout: TimeInterval, cancellation: CancellationFlag?) throws {
        try wait(timeout: timeout, cancellation: cancellation, for: "connecting") { self.isReady ? () : nil }
    }

    // MARK: Reading

    /// The next bytes, at most `count`; nil when the other side has closed the connection.
    ///
    /// A connection that broke instead of ending throws, once what arrived before is read.
    internal func read(upToCount count: Int, timeout: TimeInterval, cancellation: CancellationFlag?) throws -> Data? {
        let data: Data? = try wait(timeout: timeout, cancellation: cancellation, for: "reading") {
            () throws -> Data?? in
            if self.buffered > 0 {
                let piece = Data(self.buffer[self.readOffset..<self.readOffset + min(count, self.buffered)])
                self.consume(piece.count)
                return .some(piece)
            }
            if let broken = self.receiveFailure { throw broken }
            return self.atEnd ? .some(nil) : nil
        }
        if data != nil { resumeReceiving() }
        return data
    }

    /// The next line without its line end.
    ///
    /// Throws `connectionLost` when the connection ends first, and `unexpected` when no line end
    /// comes within `limit` bytes: a line of a reply is short, and the wait for one must not
    /// collect whatever a server sends instead.
    internal func readLine(timeout: TimeInterval, limit: Int, cancellation: CancellationFlag?) throws -> Data {
        // How far the buffer was searched already, so no byte is looked at twice.
        var searched = 0
        let line: Data? = try wait(timeout: timeout, cancellation: cancellation, for: "waiting for a reply") {
            () throws -> Data?? in
            let from = self.readOffset + min(searched, self.buffered)
            let until = min(self.buffer.count, self.readOffset + limit + 2)
            if from < until, let end = self.buffer[from..<until].firstIndex(of: 0x0A) {
                var found = self.buffer[self.readOffset..<end]
                if found.last == 0x0D { found = found.dropLast() }
                let result = Data(found)
                self.consume(end + 1 - self.readOffset)
                return .some(result)
            }
            searched = max(searched, until - self.readOffset)
            if self.buffered > limit + 1 { throw NetworkError.unexpected("a reply line of more than \(limit) bytes") }
            if let broken = self.receiveFailure { throw broken }
            return self.atEnd ? .some(nil) : nil
        }
        guard let line else { throw NetworkError.connectionLost }
        resumeReceiving()
        return line
    }

    /// True when something has arrived that was not read yet.
    internal func hasInput(within timeout: TimeInterval) -> Bool {
        (try? wait(timeout: timeout, cancellation: nil, for: "") { self.buffered == 0 && !self.atEnd ? nil : true })
            ?? false
    }

    // MARK: Writing

    /// Declares the data complete; on a stream without TLS the other side is told at once.
    ///
    /// A second call does nothing.
    internal func finishWriting(timeout: TimeInterval, cancellation: CancellationFlag?) throws {
        condition.lock()
        let alreadyFinished = hasFinishedWriting
        hasFinishedWriting = true
        condition.unlock()
        if !alreadyFinished, !isEncrypted {
            try send(nil, isFinal: true, timeout: timeout, cancellation: cancellation)
        }
    }

    /// Hands `data` to the network layer; the returned value tells whether it was sent.
    internal func submit(_ data: Data?, isFinal: Bool) -> Pending<Bool> {
        let sent = Pending<Bool>()
        connection.send(
            content: data,
            contentContext: isFinal ? .finalMessage : .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { error in sent.fulfill(error == nil) }
        )
        return sent
    }

    /// Closes the connection; waits and reads that come after fail with `connectionLost`.
    internal func close() {
        condition.lock()
        isClosed = true
        if failure == nil { failure = NetworkError.connectionLost }
        condition.broadcast()
        condition.unlock()
        connection.cancel()
    }

    /// Keeps one receive call outstanding while there is room in the buffer.
    ///
    /// Runs on the queue.
    private func receiveMore() {
        condition.lock()
        let wanted = !isReceiving && !atEnd && !isClosed && buffered < Self.highWater
        if wanted { isReceiving = true }
        condition.unlock()
        guard wanted else {
            return
        }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 256 * 1_024
        ) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }
            condition.lock()
            isReceiving = false
            // What comes after `close` is nobody's: a call that was cut off stays cut off.
            if let data, !isClosed { buffer.append(data) }
            if let error, receiveFailure == nil {
                receiveFailure = NetworkError.connectionFailed(error.localizedDescription)
            }
            if isComplete || error != nil { atEnd = true }
            condition.broadcast()
            condition.unlock()
            receiveMore()
        }
    }

    /// Takes `count` bytes off the front.
    ///
    /// Called with the lock held.
    private func consume(_ count: Int) {
        readOffset += count
        if readOffset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
        } else if readOffset >= Self.compactAt {
            buffer.removeSubrange(0..<readOffset)
            readOffset = 0
        }
    }

    /// Waits until `ready` returns a value, the stream fails, the time is up or the caller cancels.
    private func wait<Result>(
        timeout: TimeInterval,
        cancellation: CancellationFlag?,
        for what: String,
        _ ready: () throws -> Result?
    ) throws -> Result {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        var now = Date()
        repeat {
            if let result = try ready() {
                return result
            }
            if let failure { throw failure }
            if cancellation?.isCancelled == true { throw NetworkError.cancelled }
            now = Date()
            if now < deadline { condition.wait(until: min(deadline, now.addingTimeInterval(0.1))) }
        } while now < deadline
        throw NetworkError.timedOut(what)
    }

    /// Asks for more when receiving had stopped for a full buffer.
    ///
    /// Called after a read made room, with the lock not held; the queue is only bothered when there
    /// is something to do.
    private func resumeReceiving() {
        condition.lock()
        let stopped = !isReceiving && !atEnd && !isClosed && isReady
        condition.unlock()
        if stopped { queue.async { [weak self] in self?.receiveMore() } }
    }

    deinit {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}
