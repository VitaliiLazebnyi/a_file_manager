import Foundation
import TestSupport

/// An FTP server whose every answer the test writes: a script gets each command line and the
/// control connection, and replies, opens data connections or hangs up as it likes. What the
/// script leaves alone `standard` answers like a plain, agreeable server. It listens on
/// 127.0.0.1; every control connection runs on a thread of its own.
///
/// Unchecked: the record of commands, the sockets and the stop are guarded by `lock`; the rest
/// is set in `init`.
internal final class CoverageNetworkServer: @unchecked Sendable {
    /// What the script does with each command line.
    internal typealias Script = @Sendable (_ command: String, _ line: Line) -> Handling

    /// What a script returns for a command: handled, or left to `standard`.
    internal enum Handling {
        /// The script answered.
        case handled
        /// `standard` answers.
        case standard
    }

    /// One control connection, as the script sees it. Used by its own thread only.
    internal final class Line {
        /// The socket of the control connection.
        internal let socket: Int32
        /// True once the script hung up; the connection then ends.
        internal private(set) var isClosed = false
        private var pending = Data()
        private var passive: Int32?
        /// A data connection made to the client (active mode), for the next transfer.
        internal var active: Int32?

        /// A control connection on `socket`.
        internal init(socket: Int32) {
            self.socket = socket
        }

        /// Sends `text` with a line end after it.
        internal func send(_ text: String) {
            _ = CoverageNetworkServer.sendAll(socket, Data((text + "\r\n").utf8))
        }

        /// Ends the control connection after this command.
        internal func hangUp() {
            isClosed = true
        }

        /// The next command line; nil when the client hung up.
        internal func readCommand() -> String? {
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                if let end = pending.firstIndex(of: 0x0A) {
                    var line = pending[pending.startIndex..<end]
                    if line.last == 0x0D {
                        line = line.dropLast()
                    }
                    pending = Data(pending[pending.index(after: end)...])
                    return String(bytes: line, encoding: .utf8) ?? ""
                }
                let count = recv(socket, &buffer, buffer.count, 0)
                if count <= 0 {
                    return nil
                }
                pending.append(buffer, count: count)
            }
        }

        /// Listens for a data connection and returns the port.
        internal func openPassive() -> Int {
            // Forgotten as soon as it is closed (the number may soon be somebody else's).
            if let previous = passive {
                close(previous)
                passive = nil
            }
            guard let opened = try? TestFTPServer.listen() else {
                return 0
            }
            passive = opened
            return TestFTPServer.port(of: opened)
        }

        /// The data connection the client opened to the port of `openPassive`; nil when none came
        /// within `Wait.ceiling` or the client spoke on the control connection instead.
        internal func acceptData() -> Int32? {
            if let connected = active {
                active = nil
                return connected
            }
            guard let waiting = passive else {
                return nil
            }
            let deadline = Date().addingTimeInterval(Wait.ceiling)
            while Date() < deadline {
                var descriptors = [
                    pollfd(fd: waiting, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
                ]
                guard poll(&descriptors, 2, 50) > 0 else {
                    continue
                }
                if descriptors[0].revents & Int16(POLLIN) != 0 {
                    let client = accept(waiting, nil, nil)
                    return client >= 0 ? client : nil
                }
                if descriptors[1].revents != 0 {
                    return nil
                }
            }
            return nil
        }

        /// A whole download: the announcement, the data, the end of the data connection, the verdict.
        internal func transfer(_ data: Data, verdict: String) {
            send("150 Here it comes")
            guard let channel = acceptData() else {
                return
            }
            _ = CoverageNetworkServer.sendAll(channel, data)
            close(channel)
            send(verdict)
        }

        /// Sends `data` on a data connection, then waits until the client drops it, and closes it.
        internal func sendAndWaitForTheClient(_ data: Data) {
            send("150 Here it comes")
            guard let channel = acceptData() else {
                return
            }
            _ = CoverageNetworkServer.sendAll(channel, data)
            var buffer = [UInt8](repeating: 0, count: 64)
            while recv(channel, &buffer, buffer.count, 0) > 0 {
                // Until the client drops the data connection.
            }
            close(channel)
        }

        /// Everything the client sends on the data connection, until it closes it.
        internal func receiveData() -> Data? {
            guard let channel = acceptData() else {
                return nil
            }
            defer { close(channel) }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = recv(channel, &buffer, buffer.count, 0)
                if count <= 0 {
                    return data
                }
                data.append(buffer, count: count)
            }
        }

        deinit {
            if let waiting = passive {
                close(waiting)
            }
        }
    }

    /// The port the server listens on.
    internal let port: Int
    private let listener: Int32
    private let lock = NSLock()
    private var log: [String] = []
    private var isStopped = false
    private var sockets: Set<Int32> = []

    /// Every command line received, in order.
    internal var commands: [String] { lock.withLock { log } }

    private var stopped: Bool { lock.withLock { isStopped } }

    /// Starts listening. Each connection gets `greeting` first, then the script for each command.
    internal init(onIPv6: Bool, greeting: [String], script: @escaping Script) throws {
        listener = onIPv6 ? try Self.listenOnIPv6() : try TestFTPServer.listen()
        port = TestFTPServer.port(of: listener)
        let thread = Thread { [self] in
            while !stopped {
                var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 20) > 0 else {
                    continue
                }
                let client = accept(listener, nil, nil)
                guard client >= 0 else {
                    continue
                }
                lock.withLock { _ = sockets.insert(client) }
                Thread.detachNewThread { [self] in serve(client, greeting: greeting, script: script) }
            }
            close(listener)
        }
        thread.start()
    }

    /// A server on 127.0.0.1 that greets with `greeting`.
    internal convenience init(greeting: [String], script: @escaping Script) throws {
        try self.init(onIPv6: false, greeting: greeting, script: script)
    }

    /// A server with the usual greeting.
    internal convenience init(script: @escaping Script) throws {
        try self.init(greeting: ["220 Scripted server"], script: script)
    }

    /// The command's verb, in capitals.
    internal static func verb(_ command: String) -> String {
        command.split(separator: " ").first.map { $0.uppercased() } ?? ""
    }

    /// The answers of a plain server that lets everybody in and has nothing but `/`.
    internal static func standard(_ command: String, _ line: Line) {
        switch verb(command) {
        case "USER", "PASS":
            line.send("230 Welcome")

        case "FEAT":
            line.send("211-Features:\r\n UTF8\r\n SIZE\r\n MDTM\r\n EPSV\r\n211 End")

        case "OPTS", "TYPE", "NOOP", "PBSZ", "PROT":
            line.send("200 OK")

        case "SYST":
            line.send("215 UNIX Type: L8")

        case "PWD":
            line.send("257 \"/\" is the current directory")

        case "CWD", "CDUP":
            line.send("250 OK")

        case "EPSV":
            line.send("229 Entering Extended Passive Mode (|||\(line.openPassive())|)")

        case "PASV":
            let dataPort = line.openPassive()
            line.send("227 Entering Passive Mode (127,0,0,1,\(dataPort / 256),\(dataPort % 256))")

        case "QUIT":
            line.send("221 Bye")
            line.hangUp()

        default:
            line.send("502 Not here")
        }
    }

    /// Sends all of `data`; false when the other side is gone.
    internal static func sendAll(_ descriptor: Int32, _ data: Data) -> Bool {
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        return data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else {
                return true
            }
            var sent = 0
            while sent < buffer.count {
                let count = Darwin.send(descriptor, base + sent, buffer.count - sent, 0)
                if count <= 0 {
                    return false
                }
                sent += count
            }
            return true
        }
    }

    /// Stops listening and cuts every connection.
    internal func stop() {
        lock.withLock {
            isStopped = true
            sockets.forEach { _ = shutdown($0, SHUT_RDWR) }
        }
    }

    private func serve(_ socket: Int32, greeting: [String], script: Script) {
        let line = Line(socket: socket)
        greeting.forEach(line.send)
        while !line.isClosed, let command = line.readCommand() {
            lock.withLock { log.append(command) }
            if script(command, line) == .standard {
                Self.standard(command, line)
            }
        }
        lock.withLock { _ = sockets.remove(socket) }
        close(socket)
    }

    deinit {
        stop()
    }
}
