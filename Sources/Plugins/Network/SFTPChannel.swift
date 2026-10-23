import AFMKernel
import Foundation

/// An SFTP dialogue over the standard input and output of a child process, normally
/// `ssh -s host sftp`: ssh does the encryption and the login, this class speaks the file
/// protocol (SFTP version 3, with OpenSSH's `posix-rename`).
///
/// **Threading.** Requests carry numbers and the answers name them, so any number of threads
/// may have requests under way at once: each sends under `writeLock` and waits for its own
/// answer, which the reading thread hands over. No pool of connections is needed.
///
/// The state, `extensions` included, is guarded by `lock`;
/// `writeTimeout` and `names` do not change after `init`.
internal final class SFTPChannel: @unchecked Sendable {
    /// How long the last words of the child process are waited for after its output ended.
    internal static let lastWordsTime: TimeInterval = 2
    /// How long the thread that found the connection lost waits for the reading thread to see the end.
    internal static let endTime: TimeInterval = 8

    /// How long writing a packet may make no progress before the channel is given up: ssh
    /// that does not read its input is stuck, and everything waiting behind it with it.
    internal let writeTimeout: TimeInterval
    /// The names of the server that are written back as they came.
    internal let names: NameMemory?
    private let process = Process()
    private let toServer = Pipe()
    private let fromServer = Pipe()
    /// What the child process writes to its error output.
    private let errors = ProcessErrorOutput()
    private let lock = NSLock()
    /// Held while a packet is written, and while the write end of the pipe is closed.
    private let writeLock = NSLock()
    private var waiting: [UInt32: Pending<SFTPPacket>] = [:]
    private var nextID: UInt32 = 1
    private var closed = false
    /// Requests nobody waits for (a handle to be closed), complete packets in order.
    ///
    /// They go out before the next packet anyone writes, so the server sees them in the order they
    /// were asked for, and the thread that asked does not wait for the pipe.
    private var deferred: [Data] = []
    /// When the server was last heard from.
    private var lastReceived = Date()
    /// Signalled by the reading thread when the stream has ended and the last words are read.
    private let lastWords = DispatchSemaphore(value: 0)
    private let version = Pending<SFTPPacket>()
    private var serverExtensions: [String: String] = [:]

    /// The extensions the server named in its first answer; known once `start` has returned.
    internal var extensions: [String: String] { lock.withLock { serverExtensions } }

    /// True once the channel was closed, by `close` or because the dialogue ended.
    internal var isClosed: Bool { lock.withLock { closed } }

    /// What the child process wrote to its error output, e.g. why the login failed.
    internal var errorMessage: String { errors.message }

    /// A channel to the child process `executable`, not started yet; `environment` is added to
    /// this program's own.
    internal init(
        executable: String,
        arguments: [String],
        environment: [String: String],
        writeTimeout: TimeInterval,
        names: NameMemory?
    ) {
        self.writeTimeout = writeTimeout
        self.names = names
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = toServer
        process.standardOutput = fromServer
        process.standardError = errors.pipe
    }

    /// `errorMessage` once the child process has had its say: when the dialogue broke off, the
    /// reading thread first reads what the process still wrote, and this waits for that, for a
    /// moment at most.
    ///
    /// For the thread that found the connection lost and wants to say why.
    internal func errorMessageAtTheEnd() -> String {
        // The reading thread comes to the end once the process has gone; on a busy machine that
        // can take a moment longer than the process itself, so it is given a few seconds.
        if lastWords.wait(timeout: .now() + Self.lastWordsTime + Self.endTime) == .success {
            lastWords.signal()
        }
        return errorMessage
    }

    /// Starts the process and the protocol.
    ///
    /// `service` is called a few times a second while the login is under way, to answer ssh's
    /// questions; it returns false to give up.
    internal func start(timeout: TimeInterval, cancellation: CancellationFlag?, service: () -> Bool) throws {
        errors.collect()
        try launch()
        startReading()
        var hello = SFTPEncoder()
        hello.beginPacket(1, id: nil)
        hello.u32(3)
        hello.finishPacket()
        try write(hello.data, cancellation: nil)
        var deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let packet = try version.wait(timeout: 0.1, cancellation: cancellation) {
                var decoder = try packet.expect(.version)
                _ = try decoder.u32()
                var named: [String: String] = [:]
                while !decoder.isAtEnd, let name = try? decoder.string(), let value = try? decoder.string() {
                    named[name] = value
                }
                lock.withLock { serverExtensions = named }
                return
            }
            let asked = Date()
            guard service() else { throw NetworkError.cancelled }
            // The time the user took to answer does not count.
            deadline.addTimeInterval(Date().timeIntervalSince(asked))
        } while Date() <= deadline
        throw NetworkError.timedOut("logging in")
    }

    /// Sends a request whose answer nobody needs (closing a handle that was only read, or one of
    /// a transfer that was given up).
    ///
    /// Returns at once, from any thread: the packet is put in line and written before the next
    /// request, by whoever writes next or, when nobody does, in the background. The server
    /// therefore sees it before anything that is asked afterwards (the removal of a file whose
    /// handle is closed here).
    internal func sendWithoutAnswer(_ type: SFTPRequest, _ build: (inout SFTPEncoder) -> Void) {
        var packet = SFTPEncoder()
        packet.names = names
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        let id = nextID
        nextID &+= 1
        packet.beginPacket(type.rawValue, id: id)
        build(&packet)
        packet.finishPacket()
        deferred.append(packet.data)
        lock.unlock()
        Background.run(lane: self) { [weak self] in try? self?.write(nil, cancellation: nil) }
    }

    /// Sends a request without waiting; several can be under way and are answered in any order.
    internal func send(_ type: SFTPRequest, cancellation: CancellationFlag?, _ build: (inout SFTPEncoder) -> Void)
        throws
        -> Ticket
    {
        if cancellation?.isCancelled == true { throw NetworkError.cancelled }
        let answer = Pending<SFTPPacket>()
        // A closed channel is found out by `write`, which looks under the lock it writes with.
        lock.lock()
        let id = nextID
        nextID &+= 1
        waiting[id] = answer
        lock.unlock()
        var packet = SFTPEncoder()
        packet.names = names
        packet.beginPacket(type.rawValue, id: id)
        build(&packet)
        packet.finishPacket()
        do {
            try write(packet.data, cancellation: cancellation)
        } catch {
            lock.lock()
            waiting[id] = nil
            lock.unlock()
            throw error
        }
        return Ticket(id: id, answer: answer)
    }

    /// Stops expecting the answer of a request.
    ///
    /// If it still comes it is dropped.
    internal func abandon(_ ticket: Ticket) {
        lock.lock()
        waiting[ticket.id] = nil
        lock.unlock()
    }

    /// Waits for one answer.
    ///
    /// When it takes too long only this request is given up: the answers are matched by number, so
    /// the others are not affected, and a server that is merely slow with one request does not lose
    /// every transfer that is running. But when nothing at all arrived from the server in that
    /// time, the connection is taken for dead and the channel is closed: every later request would
    /// otherwise wait out its own time limit on it, one after the other. The next request opens a
    /// new channel.
    internal func wait(for ticket: Ticket, timeout: TimeInterval, cancellation: CancellationFlag?) throws
        -> SFTPPacket
    {
        let began = Date()
        let packet: SFTPPacket?
        do {
            packet = try ticket.answer.wait(timeout: timeout, cancellation: cancellation)
        } catch {
            abandon(ticket)
            throw error
        }
        guard let packet else {
            abandon(ticket)
            lock.lock()
            let isSilent = lastReceived < began
            lock.unlock()
            if isSilent { close() }
            throw NetworkError.timedOut("waiting for the server")
        }
        if packet.kind == .closed { throw NetworkError.connectionLost }
        return packet
    }

    /// Ends the dialogue and the child process.
    ///
    /// Returns at once, from any thread.
    internal func close() {
        errors.stopCollecting()
        // Marked closed first: a `start` under way then either starts nothing, or has started
        // the process by now (it holds `lock` meanwhile), which is ended here.
        markClosed()
        if process.isRunning { process.terminate() }
        // The write end goes when no writer is using it. A writer finds the channel closed
        // before its next write into the pipe, or after a wait of a fifth of a second for room
        // in it; until then the pipe is closed in the background, so this thread (possibly the
        // main thread) does not wait for it.
        let (gate, input) = (writeLock, toServer.fileHandleForWriting)
        if gate.try() {
            try? input.close()
            gate.unlock()
        } else {
            Background.run(lane: gate) {
                gate.lock()
                try? input.close()
                gate.unlock()
            }
        }
    }

    /// Starts the child process, unless the channel was closed already.
    private func launch() throws {
        // The channel may be closed from another thread (a disconnect) at any moment, also
        // before the process runs. The process is started with `lock` held, so `close`, which
        // marks the channel closed first, either comes before (and nothing is started) or finds
        // the process running and ends it; the write end of the pipe is only closed after that.
        try lock.withLock {
            guard !closed else { throw NetworkError.connectionLost }
            // A write into a pipe whose reader died must fail, not kill this program. It must not
            // block either: a packet that cannot be written is waited for with a time limit.
            let input = toServer.fileHandleForWriting.fileDescriptor
            _ = fcntl(input, F_SETNOSIGPIPE, 1)
            _ = fcntl(input, F_SETFL, fcntl(input, F_GETFL) | O_NONBLOCK)
            do {
                try process.run()
            } catch {
                throw NetworkError.connectionFailed(error.localizedDescription)
            }
        }
    }

    /// Starts the thread that reads the answers and hands them to their requests.
    private func startReading() {
        // The thread holds the reading end of the pipe, which stays open until it is done,
        // whatever happens to the channel.
        let output = fromServer.fileHandleForReading
        let ended = lastWords
        let reader = Thread { [weak self] in
            Self.readPackets(from: output) { self?.received($0) ?? false }
            // The stream ended, or what came was not SFTP: the dialogue is over, and ssh with it.
            // What ssh said last (why the login failed) is read before anyone is told: its two
            // outputs end together, and the end of one may be seen before the text of the other.
            self?.errors.drain(for: Self.lastWordsTime)
            self?.close()
            ended.signal()
        }
        reader.name = "afm.network.sftp"
        reader.start()
    }

    /// Hands an answer to the request that waits for it; false ends the reading.
    private func received(_ packet: SFTPPacket) -> Bool {
        if packet.kind == .version {
            version.fulfill(packet)
            return true
        }
        var decoder = SFTPDecoder(packet.body)
        guard let id = try? decoder.u32() else {
            return false
        }
        lock.lock()
        lastReceived = Date()
        let waiter = waiting.removeValue(forKey: id)
        lock.unlock()
        waiter?.fulfill(SFTPPacket(kind: packet.kind, body: packet.body.dropFirst(4)))
        return true
    }

    private func markClosed() {
        lock.lock()
        closed = true
        let all = waiting.values
        waiting = [:]
        deferred = []
        lock.unlock()
        let end = SFTPPacket(kind: .closed, body: Data())
        version.fulfill(end)
        for waiter in all {
            waiter.fulfill(end)
        }
    }

    /// Takes the right to write, waiting in short turns so that a cancellation is noticed.
    private func lockForWriting(cancellation: CancellationFlag?) throws {
        let deadline = Date().addingTimeInterval(writeTimeout)
        while !writeLock.lock(before: min(deadline, Date().addingTimeInterval(0.1))) {
            if cancellation?.isCancelled == true { throw NetworkError.cancelled }
            if Date() >= deadline { throw NetworkError.timedOut("sending to the server") }
        }
    }

    private func writeAll(_ packet: Data, to descriptor: Int32, cancellation: CancellationFlag?) throws {
        try Self.writeAll(packet, to: descriptor, writeTimeout: writeTimeout, cancellation: cancellation) { isClosed }
    }

    /// Writes one complete packet, after the packets that were put aside for it
    /// (`sendWithoutAnswer`).
    ///
    /// Any failure in the middle of a packet leaves the dialogue unusable and ends the channel; a
    /// cancellation that comes before the first byte does not.
    private func write(_ packet: Data?, cancellation: CancellationFlag?) throws {
        do {
            try lockForWriting(cancellation: cancellation)
            defer { writeLock.unlock() }
            while true {
                lock.lock()
                let isOver = closed
                let queued = deferred
                deferred = []
                lock.unlock()
                // The pipe is only closed with `writeLock` held and the channel marked closed,
                // so past this check its descriptor is good for as long as the lock is held.
                guard !isOver else { throw NetworkError.connectionLost }
                if queued.isEmpty { break }
                // These are owed to the server whatever becomes of the caller.
                let descriptor = toServer.fileHandleForWriting.fileDescriptor
                for owed in queued { try writeAll(owed, to: descriptor, cancellation: nil) }
            }
            if let packet {
                try writeAll(packet, to: toServer.fileHandleForWriting.fileDescriptor, cancellation: cancellation)
            }
        } catch NetworkError.cancelled {
            throw NetworkError.cancelled
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }
}
