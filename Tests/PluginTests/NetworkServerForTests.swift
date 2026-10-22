import Foundation
import TestSupport

/// A small FTP server for the tests: it listens on 127.0.0.1 on a port the system picks and
/// serves a folder of the test's sandbox.
///
/// One thread per control connection, plain BSD sockets. It speaks enough of the protocol to be a
/// believable server, and can be made to behave like the awkward ones (no MLSD, DOS listings, no
/// EPSV, a password, dropped connections). Unchecked: what changes is guarded by `lock`; the rest
/// is set in `init`.
internal final class TestFTPServer: @unchecked Sendable {
    internal struct Options {
        internal var offersMLSD = true
        internal var offersFeatures = true
        internal var offersEPSV = true
        internal var offersSize = true
        internal var dosListing = false
        /// Nil: anyone may log in.
        internal var user: String?
        internal var password = ""
        /// A pause before every listing, to make listings overlap.
        internal var listDelay: TimeInterval = 0
        /// Lines added to the end of every listing as they are, e.g. names a server must not be believed.
        internal var injectedLines: [String] = []
        /// The first connections are answered with 421 (too many from this address) and closed.
        internal var busyGreetings = 0
        /// This command is carried out, but its reply is never sent: the connection is cut instead.
        internal var dropReplyFor: String?
        /// RETR opens the data connection and then sends nothing at all.
        internal var stallRETR = false
        /// RETR sends this many bytes and then resets the data connection.
        internal var resetRETRAfter: Int?
        /// STOR opens the data connection and then reads nothing at all.
        internal var stallSTOR = false
        /// FEAT does not list REST.
        internal var offersREST = true
        /// RNTO is refused when something has the new name, as on servers whose rename does not replace.
        internal var renameKeepsExisting = false
        /// RNTO is refused for a source whose path ends like this (`*` refuses every rename).
        internal var refusesRenameOf: String?
        /// DELE is refused.
        internal var refusesDelete = false
        /// APPE starts the file anew, as a server does that takes it for STOR.
        internal var appendStartsAnew = false
        /// Of an upload only this many bytes are kept, and the server says 226 all the same.
        internal var keepsOfUploads: Int?
        /// What a listing sends instead of the folder's lines, byte for byte.
        internal var rawListing: Data?
        /// The reply to this command never ends: lines of it are sent for as long as the client listens.
        internal var endlessReplyTo: String?
        /// The reply to this command is one line of this many bytes without a line end.
        internal var longLineReplyTo: (verb: String, bytes: Int)?
        /// A pause before the greeting.
        internal var greetingDelay: TimeInterval = 0
        /// In active mode the data connection is never opened: after the 150 comes a 425, after this long.
        internal var activeNeverConnects: TimeInterval?
        /// A transfer is announced twice (`125`, and `150` once the data is through), as some servers do.
        internal var announcesTwice = false
    }

    /// The listening socket and the thread that accepts on it.
    ///
    /// The thread alone closes the socket, once it has seen `isStopped` and is no longer inside a
    /// call on it: a descriptor that is closed under a thread which is about to call `accept` on it
    /// may by then be the number of another server's socket in this process (the tests run side by
    /// side), and that thread would take the other server's connections. Unchecked: `stopped` is
    /// guarded by `lock`; the rest is set in `init`.
    private final class Acceptor: @unchecked Sendable {
        let listener: Int32
        private let lock = NSLock()
        private var stopped = false
        private let ended = DispatchSemaphore(value: 0)

        var isStopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }

        init(listener: Int32) { self.listener = listener }

        /// Returns when the socket is closed and nothing is accepted any more.
        func stop() {
            lock.lock()
            let wasStopped = stopped
            stopped = true
            lock.unlock()
            guard !wasStopped else {
                return
            }
            ended.wait()
        }

        func run(_ take: @escaping @Sendable (Int32) -> Bool) {
            let thread = Thread { [self] in
                while !isStopped {
                    var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                    guard poll(&descriptor, 1, 20) > 0 else { continue }
                    let client = accept(listener, nil, nil)
                    guard client >= 0 else { continue }
                    if isStopped || !take(client) { close(client) }
                }
                close(listener)
                ended.signal()
            }
            thread.name = "test.ftp.accept"
            thread.start()
        }
    }

    internal let root: URL
    internal let port: Int
    private let acceptor: Acceptor
    private let lock = NSLock()
    private var currentOptions: Options
    private var clients: Set<Int32> = []
    private var commandLog: [String] = []
    private var opened = 0
    private var listing = 0
    private var mostListing = 0
    private var stopped = false
    private var peak = 0
    private var busy = 0

    internal var options: Options {
        get {
            lock.lock()
            defer { lock.unlock() }
            return currentOptions
        }
        set {
            lock.lock()
            currentOptions = newValue
            lock.unlock()
        }
    }

    /// Every command line received, in order.
    internal var commands: [String] {
        lock.lock()
        defer { lock.unlock() }
        return commandLog
    }
    /// How many control connections were ever opened.
    internal var connectionsOpened: Int {
        lock.lock()
        defer { lock.unlock() }
        return opened
    }
    internal var openConnections: Int {
        lock.lock()
        defer { lock.unlock() }
        return clients.count
    }
    /// The most control connections that were open at the same moment.
    internal var mostConnectionsAtOnce: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }
    internal var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
    /// The largest number of listings that ran at the same moment.
    internal var mostListingsAtOnce: Int {
        lock.lock()
        defer { lock.unlock() }
        return mostListing
    }

    internal init(root: URL, options: Options = Options()) throws {
        self.root = root
        currentOptions = options
        let listener = try Self.listen()
        port = Self.port(of: listener)
        acceptor = Acceptor(listener: listener)
        acceptor.run { [weak self] client in
            guard let self else {
                return false
            }
            lock.lock()
            // Stopped between the accept and here: `stop` has cut the connections it knew.
            if stopped {
                lock.unlock()
                return false
            }
            clients.insert(client)
            peak = max(peak, clients.count)
            opened += 1
            lock.unlock()
            Thread.detachNewThread { Session(server: self, socket: client).run() }
            return true
        }
    }

    // MARK: Sockets

    internal static func listen() throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(descriptor, 64) == 0 else {
            close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }
        return descriptor
    }

    internal static func port(of descriptor: Int32) -> Int {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    fileprivate static func connect(to host: String, port: Int) -> Int32? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr(host)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    fileprivate static func sendAll(_ descriptor: Int32, _ data: Data) -> Bool {
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        return data.withUnsafeBytes { buffer -> Bool in
            var sent = 0
            while sent < buffer.count {
                let count = send(descriptor, buffer.baseAddress! + sent, buffer.count - sent, 0)
                if count <= 0 {
                    return false
                }
                sent += count
            }
            return true
        }
    }

    fileprivate static func receiveAll(_ descriptor: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count <= 0 {
                return data
            }
            data.append(buffer, count: count)
        }
    }

    internal func stop() {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        lock.unlock()
        guard !wasStopped else {
            return
        }
        acceptor.stop()
        dropConnections()
    }

    /// Cuts every control connection, like a server that timed its clients out.
    internal func dropConnections() {
        // Under the lock: a session takes its socket out of the list, under the same lock,
        // before it closes it, so no descriptor is shut down here that is somebody else's by now.
        lock.lock()
        clients.forEach { shutdown($0, SHUT_RDWR) }
        lock.unlock()
    }

    fileprivate func record(_ command: String) {
        lock.lock()
        commandLog.append(command)
        lock.unlock()
    }

    /// Closes the socket of a session that ended.
    ///
    /// It leaves the list first (see `dropConnections`).
    fileprivate func closed(_ client: Int32) {
        lock.lock()
        clients.remove(client)
        lock.unlock()
        close(client)
    }

    /// True while connections are still to be refused with 421.
    fileprivate func refusesGreeting() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard busy < currentOptions.busyGreetings else {
            return false
        }
        busy += 1
        return true
    }

    fileprivate func listingStarted() {
        lock.lock()
        listing += 1
        mostListing = max(mostListing, listing)
        lock.unlock()
    }

    fileprivate func listingEnded() {
        lock.lock()
        listing -= 1
        lock.unlock()
    }

    /// Waits for the data connection: until it comes, until the client says something else on
    /// the control connection or hangs up (it gave the transfer up), until the server stops,
    /// `Wait.ceiling` at most.
    ///
    /// No short limit: a client on a machine that is busy with other tests may take seconds to get
    /// to its `connect`.
    fileprivate func acceptOne(_ listener: Int32, control: Int32) -> Int32? {
        let deadline = Date().addingTimeInterval(Wait.ceiling)
        while !isStopped, Date() < deadline {
            var descriptors = [
                pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
                pollfd(fd: control, events: Int16(POLLIN), revents: 0)
            ]
            guard poll(&descriptors, 2, 50) > 0 else { continue }
            if descriptors[0].revents & Int16(POLLIN) != 0 {
                let client = accept(listener, nil, nil)
                return client >= 0 ? client : nil
            }
            if descriptors[1].revents != 0 {
                return nil
            }
        }
        return nil
    }

    deinit { stop() }
}

/// One control connection of the test server.
private final class Session {
    private static let stampFormat = formatter("yyyyMMddHHmmss", utc: true)
    private static let recentFormat = formatter("MMM dd HH:mm", utc: false)
    private static let oldFormat = formatter("MMM dd  yyyy", utc: false)
    private static let dosFormat = formatter("MM-dd-yy  hh:mma", utc: false)

    private let server: TestFTPServer
    private let socket: Int32
    private let fm = FileManager.default
    private var directory = "/"
    private var user = ""
    private var loggedIn = false
    private var passive: Int32?
    private var active: (host: String, port: Int)?
    private var restart: UInt64 = 0
    private var renameFrom: String?
    private var pending = Data()
    /// Set while a command whose reply must not be sent is carried out.
    private var muted = false

    init(server: TestFTPServer, socket: Int32) {
        self.server = server
        self.socket = socket
    }

    private static func formatter(_ format: String, utc: Bool) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        if utc { formatter.timeZone = TimeZone(identifier: "UTC") }
        return formatter
    }

    func run() {
        if server.refusesGreeting() {
            reply("421 Too many connections from your address")
            server.closed(socket)
            return
        }
        if server.options.greetingDelay > 0 { Thread.sleep(forTimeInterval: server.options.greetingDelay) }
        reply("220 Test server ready")
        while let line = readLine() {
            server.record(line)
            let parts = line.split(separator: " ", maxSplits: 1)
            guard let verb = parts.first?.uppercased() else { continue }
            if server.options.endlessReplyTo?.uppercased() == verb {
                // Until the client hangs up, or the test ends.
                let filler = Data(("200-" + String(repeating: "x", count: 200) + "\r\n").utf8)
                while !server.isStopped, TestFTPServer.sendAll(socket, filler) {}
                break
            }
            if let long = server.options.longLineReplyTo, long.verb.uppercased() == verb {
                _ = TestFTPServer.sendAll(socket, Data(repeating: 0x78, count: long.bytes))
                while !server.isStopped { Thread.sleep(forTimeInterval: 0.05) }
                break
            }
            muted = server.options.dropReplyFor?.uppercased() == verb
            if !handle(verb, parts.count > 1 ? String(parts[1]) : "") || muted { break }
        }
        if let passive { close(passive) }
        server.closed(socket)
    }

    private func readLine() -> String? {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            if let end = pending.firstIndex(of: 0x0A) {
                var line = pending[pending.startIndex..<end]
                if line.last == 0x0D { line = line.dropLast() }
                let text = String(decoding: line, as: UTF8.self)
                pending = Data(pending[pending.index(after: end)...])
                return text
            }
            let count = recv(socket, &buffer, buffer.count, 0)
            if count <= 0 {
                return nil
            }
            pending.append(buffer, count: count)
        }
    }

    private func reply(_ text: String) {
        if muted {
            return
        }
        _ = TestFTPServer.sendAll(socket, Data((text + "\r\n").utf8))
    }

    /// The real path of a path the client named; nil when it would leave the served folder.
    private func local(_ path: String) -> URL? {
        let combined = path.hasPrefix("/") ? path : directory + "/" + path
        var names: [Substring] = []
        for name in combined.split(separator: "/") {
            if name == ".." { _ = names.popLast() } else if name != "." { names.append(name) }
        }
        return names.isEmpty ? server.root : server.root.appendingPathComponent(names.joined(separator: "/"))
    }

    private func virtual(_ url: URL) -> String {
        let path = String(url.path.dropFirst(server.root.path.count))
        return path.isEmpty ? "/" : path
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func handle(_ verb: String, _ argument: String) -> Bool {
        let options = server.options
        switch verb {
        case "USER":
            user = argument
            reply(options.user == nil ? "230 Welcome" : "331 Password please")
            loggedIn = options.user == nil
            return true

        case "PASS":
            loggedIn = options.user == nil || (user == options.user && argument == options.password)
            reply(loggedIn ? "230 Welcome" : "530 Login incorrect")
            return true

        case "QUIT":
            reply("221 Bye")
            return false

        case "AUTH", "PBSZ", "PROT":
            reply("502 No TLS here")
            return true

        default:
            break
        }
        guard loggedIn else {
            reply("530 Please log in")
            return true
        }
        switch verb {
        case "SYST":
            reply("215 UNIX Type: L8")

        case "FEAT":
            guard options.offersFeatures else {
                reply("502 Not implemented")
                break
            }
            var lines = ["211-Features:", " UTF8", " MDTM", " MFMT"]
            if options.offersREST { lines.append(" REST STREAM") }
            if options.offersSize { lines.append(" SIZE") }
            if options.offersMLSD { lines += [" MLST type*;size*;modify*;UNIX.mode*;", " MLSD"] }
            if options.offersEPSV { lines.append(" EPSV") }
            lines.append("211 End")
            reply(lines.joined(separator: "\r\n"))

        case "OPTS":
            reply("200 OK")

        case "NOOP":
            reply("200 OK")

        case "PWD":
            reply("257 \"\(directory.replacingOccurrences(of: "\"", with: "\"\""))\" is the current directory")

        case "CWD", "CDUP":
            guard let url = local(verb == "CDUP" ? ".." : argument), isDirectory(url) else {
                reply("550 No such directory")
                break
            }
            directory = virtual(url)
            reply("250 OK")

        case "TYPE":
            reply("200 Type set")

        case "PASV", "EPSV":
            guard verb == "PASV" || options.offersEPSV else {
                reply("500 Unknown command")
                break
            }
            // Forgotten as soon as it is closed: should no new one be had, the number may soon be
            // somebody else's, and a later transfer or the end of the session would close that.
            if let old = passive {
                close(old)
                passive = nil
            }
            guard let listener = try? TestFTPServer.listen() else {
                reply("425 No port")
                break
            }
            passive = listener
            active = nil
            let port = TestFTPServer.port(of: listener)
            reply(
                verb == "PASV"
                    ? "227 Entering Passive Mode (127,0,0,1,\(port / 256),\(port % 256))"
                    : "229 Entering Extended Passive Mode (|||\(port)|)"
            )

        case "PORT":
            let numbers = argument.split(separator: ",").compactMap { Int($0) }
            guard numbers.count == 6 else {
                reply("501 Bad address")
                break
            }
            active = (numbers[0..<4].map(String.init).joined(separator: "."), numbers[4] * 256 + numbers[5])
            reply("200 PORT OK")

        case "EPRT":
            let fields = argument.split(separator: "|")
            guard fields.count == 3, let port = Int(fields[2]) else {
                reply("501 Bad address")
                break
            }
            active = (String(fields[1]), port)
            reply("200 EPRT OK")

        case "REST":
            restart = UInt64(argument) ?? 0
            reply("350 Restarting at \(restart)")

        case "LIST", "NLST", "MLSD":
            guard verb != "MLSD" || options.offersMLSD else {
                reply("500 Unknown command")
                break
            }
            let showHidden = verb == "MLSD" || argument.hasPrefix("-") && argument.contains("a")
            let path = verb == "MLSD" ? argument : (argument.hasPrefix("-") ? "" : argument)
            guard let url = local(path), isDirectory(url) else {
                reply("550 No such directory")
                break
            }
            server.listingStarted()
            if options.listDelay > 0 {
                // In slices: a server that is stopped does not keep its thread for the whole pause.
                let end = Date().addingTimeInterval(options.listDelay)
                while !server.isStopped, Date() < end {
                    Thread.sleep(forTimeInterval: min(0.05, max(0, end.timeIntervalSinceNow)))
                }
            }
            let names = ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
                .filter {
                    showHidden || !$0.hasPrefix(".")
                }
            let lines =
                names.map {
                    line(for: url.appendingPathComponent($0), name: $0, mlsd: verb == "MLSD", dos: options.dosListing)
                }
                + options.injectedLines
            let preamble = verb == "LIST" && !options.dosListing ? "total \(names.count)\r\n" : ""
            let listing = options.rawListing ?? Data((preamble + lines.map { $0 + "\r\n" }.joined()).utf8)
            transfer { TestFTPServer.sendAll($0, listing) }
            server.listingEnded()

        case "MLST":
            guard options.offersMLSD else {
                reply("500 Unknown command")
                break
            }
            guard let url = local(argument), fm.fileExists(atPath: url.path) else {
                reply("550 Not found")
                break
            }
            reply("250-Listing\r\n \(line(for: url, name: virtual(url), mlsd: true, dos: false))\r\n250 End")

        case "SIZE":
            guard options.offersSize else {
                reply("500 Unknown command")
                break
            }
            guard let url = local(argument), fm.fileExists(atPath: url.path), !isDirectory(url) else {
                reply("550 Not a file")
                break
            }
            reply("213 \(size(of: url))")

        case "MDTM":
            guard let url = local(argument), fm.fileExists(atPath: url.path), !isDirectory(url) else {
                reply("550 Not a file")
                break
            }
            reply("213 \(stamp(modified(url)))")

        case "MFMT":
            let parts = argument.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let url = local(String(parts[1])),
                let date = Self.stampFormat.date(from: String(parts[0]))
            else {
                reply("501 Bad arguments")
                break
            }
            try? fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            reply("213 Modify=\(parts[0]); \(parts[1])")

        case "SITE":
            let parts = argument.split(separator: " ", maxSplits: 2)
            guard parts.count == 3, parts[0].uppercased() == "CHMOD", let mode = Int(parts[1], radix: 8),
                let url = local(String(parts[2]))
            else {
                reply("500 Unknown SITE command")
                break
            }
            try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            reply("200 CHMOD OK")

        case "RETR":
            guard let url = local(argument), !isDirectory(url), let data = try? Data(contentsOf: url) else {
                reply("550 No such file")
                break
            }
            let offset = Int(min(restart, UInt64(data.count)))
            restart = 0
            if options.stallRETR {
                return stalled()
            }
            if let limit = options.resetRETRAfter {
                transfer { connection in
                    _ = TestFTPServer.sendAll(connection, data.subdata(in: offset..<min(data.count, offset + limit)))
                    // A reset instead of an orderly end.
                    var linger = linger(l_onoff: 1, l_linger: 0)
                    setsockopt(connection, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<linger>.size))
                    return false
                }
                break
            }
            transfer { TestFTPServer.sendAll($0, data.subdata(in: offset..<data.count)) }

        case "STOR", "APPE":
            guard let url = local(argument), isDirectory(url.deletingLastPathComponent()), !isDirectory(url) else {
                reply("553 Cannot create the file")
                break
            }
            let offset = restart
            restart = 0
            if options.stallSTOR {
                return stalled()
            }
            transfer { connection in
                var received = TestFTPServer.receiveAll(connection)
                if let kept = options.keepsOfUploads { received = received.prefix(kept) }
                guard (verb == "APPE" && !options.appendStartsAnew) || offset > 0 else {
                    return (try? received.write(to: url)) != nil
                }
                // Continuing: like most servers, nothing beyond the new data is cut off.
                if !self.fm.fileExists(atPath: url.path) { self.fm.createFile(atPath: url.path, contents: nil) }
                guard let handle = try? FileHandle(forWritingTo: url) else {
                    return false
                }
                defer { try? handle.close() }
                do {
                    if verb == "APPE" { try handle.seekToEnd() } else { try handle.seek(toOffset: offset) }
                    try handle.write(contentsOf: received)
                    return true
                } catch {
                    return false
                }
            }

        case "DELE":
            guard let url = local(argument), fm.fileExists(atPath: url.path), !isDirectory(url) else {
                reply("550 No such file")
                break
            }
            if options.refusesDelete {
                reply("550 Permission denied")
                break
            }
            reply((try? fm.removeItem(at: url)) != nil ? "250 Deleted" : "550 Cannot delete")

        case "RMD":
            guard let url = local(argument), isDirectory(url) else {
                reply("550 Not a directory")
                break
            }
            reply(rmdir(url.path) == 0 ? "250 Removed" : "550 Directory not empty")

        case "MKD":
            guard let url = local(argument), !fm.fileExists(atPath: url.path) else {
                reply("550 Already exists")
                break
            }
            reply(
                (try? fm.createDirectory(at: url, withIntermediateDirectories: false)) != nil
                    ? "257 \"\(virtual(url))\" created" : "550 Cannot create"
            )

        case "RNFR":
            guard let url = local(argument), fm.fileExists(atPath: url.path) else {
                reply("550 No such file")
                break
            }
            renameFrom = url.path
            reply("350 Ready for RNTO")

        case "RNTO":
            guard let from = renameFrom, let url = local(argument) else {
                reply("503 RNFR first")
                break
            }
            renameFrom = nil
            if let refused = options.refusesRenameOf, refused == "*" || from.hasSuffix(refused) {
                reply("550 Permission denied")
                break
            }
            if options.renameKeepsExisting, fm.fileExists(atPath: url.path) {
                reply("550 File exists")
                break
            }
            reply(rename(from, url.path) == 0 ? "250 Renamed" : "550 Cannot rename")

        default:
            reply("500 Unknown command")
        }
        return true
    }

    /// A transfer that starts and then never sends anything, until the server stops.
    private func stalled() -> Bool {
        transfer { _ in
            while !server.isStopped { Thread.sleep(forTimeInterval: 0.05) }
            return false
        }
        return true
    }

    /// Opens the data connection the client asked for, runs `work` on it and reports the result.
    private func transfer(_ work: (Int32) -> Bool) {
        var connection: Int32?
        if let listener = passive {
            reply("150 Opening data connection")
            connection = server.acceptOne(listener, control: socket)
            close(listener)
            passive = nil
        } else if let active {
            reply("150 Opening data connection")
            self.active = nil
            if let delay = server.options.activeNeverConnects {
                Thread.sleep(forTimeInterval: delay)
                reply("425 Cannot open the data connection")
                return
            }
            connection = TestFTPServer.connect(to: active.host, port: active.port)
        } else {
            reply("425 Use PASV or PORT first")
            return
        }
        guard let connection else {
            reply("425 Cannot open the data connection")
            return
        }
        let succeeded = work(connection)
        close(connection)
        if server.options.announcesTwice { reply("150 Still at it") }
        reply(succeeded ? "226 Transfer complete" : "426 Transfer aborted")
    }

    // MARK: Listing lines

    private func size(of url: URL) -> Int64 {
        ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func modified(_ url: URL) -> Date {
        ((try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? Date()
    }

    private func stamp(_ date: Date) -> String { Self.stampFormat.string(from: date) }

    private func line(for url: URL, name: String, mlsd: Bool, dos: Bool) -> String {
        let (isFolder, date, bytes) = (isDirectory(url), modified(url), size(of: url))
        let mode = ((try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        if mlsd {
            return
                "type=\(isFolder ? "dir" : "file");size=\(bytes);modify=\(stamp(date));UNIX.mode=0\(String(mode, radix: 8)); \(name)"
        }
        if dos {
            return
                "\(Self.dosFormat.string(from: date))  \(isFolder ? "     <DIR>         " : String(format: "%19lld", bytes)) \(name)"
        }
        let letters = (0..<9)
            .map { index -> Character in
                mode & (1 << (8 - index)) != 0 ? Array("rwxrwxrwx")[index] : "-"
            }
        if let target = try? fm.destinationOfSymbolicLink(atPath: url.path) {
            let isOld = date < Date().addingTimeInterval(-180 * 86_400)
            let when = (isOld ? Self.oldFormat : Self.recentFormat).string(from: date)
            return
                "lrwxrwxrwx   1 owner    group    \(String(format: "%10lld", Int64(target.utf8.count))) \(when) \(name) -> \(target)"
        }
        let isOld = date < Date().addingTimeInterval(-180 * 86_400) || date > Date().addingTimeInterval(3_600)
        let when = (isOld ? Self.oldFormat : Self.recentFormat).string(from: date)
        return
            "\(isFolder ? "d" : "-")\(String(letters))   1 owner    group    \(String(format: "%10lld", bytes)) \(when) \(name)"
    }
}
