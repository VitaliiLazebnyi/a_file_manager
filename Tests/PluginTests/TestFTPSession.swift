import Foundation

/// One control connection of the test server.
///
/// It runs on a thread of its own (see `TestFTPServer`) and is used by that thread alone, so it
/// needs no lock; what it shares with the server goes through the server's lock.
internal final class TestFTPSession {
    /// A command line the client sent: the verb in capitals and the rest of the line.
    internal struct Command {
        /// The command word, in capitals (`RETR`).
        internal let verb: String
        /// What follows the verb and a space; empty when nothing does.
        internal let argument: String
    }

    /// The commands that work before the login: verb, then what it does.
    private static let beforeLogin: [String: @Sendable (TestFTPSession, Command) -> Void] = [
        "USER": { $0.logIn(user: $1.argument) },
        "PASS": { $0.logIn(password: $1.argument) },
        "AUTH": { session, _ in session.reply("502 No TLS here") },
        "PBSZ": { session, _ in session.reply("502 No TLS here") },
        "PROT": { session, _ in session.reply("502 No TLS here") }
    ]

    /// The commands that need a login: verb, then what it does.
    ///
    /// A verb not in here is unknown.
    private static let afterLogin: [String: @Sendable (TestFTPSession, Command) -> Void] = [
        "SYST": { session, _ in session.reply("215 UNIX Type: L8") },
        "FEAT": { session, _ in session.features() },
        "OPTS": { session, _ in session.reply("200 OK") },
        "NOOP": { session, _ in session.reply("200 OK") },
        "PWD": { session, _ in session.printDirectory() },
        "CWD": { $0.changeDirectory(to: $1.argument) },
        "CDUP": { session, _ in session.changeDirectory(to: "..") },
        "TYPE": { session, _ in session.reply("200 Type set") },
        "PASV": { $0.listenPassively($1) },
        "EPSV": { $0.listenPassively($1) },
        "PORT": { $0.connectActively(port: $1.argument) },
        "EPRT": { $0.connectActively(extendedPort: $1.argument) },
        "REST": { $0.restart(from: $1.argument) },
        "LIST": { $0.list($1) },
        "NLST": { $0.list($1) },
        "MLSD": { $0.list($1) },
        "MLST": { $0.listOne($1.argument) },
        "SIZE": { $0.reportSize($1.argument) },
        "MDTM": { $0.modificationTime($1.argument) },
        "MFMT": { $0.setModificationTime($1.argument) },
        "SITE": { $0.site($1.argument) },
        "RETR": { $0.retrieve($1.argument) },
        "STOR": { $0.store($1) },
        "APPE": { $0.store($1) },
        "DELE": { $0.delete($1.argument) },
        "RMD": { $0.removeDirectory($1.argument) },
        "MKD": { $0.makeDirectory($1.argument) },
        "RNFR": { $0.renameFrom($1.argument) },
        "RNTO": { $0.renameTo($1.argument) }
    ]

    /// The server this connection belongs to.
    internal let server: TestFTPServer
    /// The control connection's socket.
    internal let socket: Int32
    /// The file manager that reads and changes the served folder.
    internal let fileManager = FileManager.default
    /// The current directory, as the client sees it (`/` is the served folder).
    internal var directory = "/"
    /// The name the client gave with USER.
    internal var user = ""
    /// True once USER (and PASS, when the server wants one) let the client in.
    internal var loggedIn = false
    /// The socket that waits for the passive data connection, after PASV or EPSV.
    internal var passive: Int32?
    /// Where to open the active data connection, after PORT or EPRT.
    internal var active: (host: String, port: Int)?
    /// The offset REST gave for the next transfer.
    internal var restartOffset: UInt64 = 0
    /// The real path RNFR named, until RNTO comes.
    internal var renameSource: String?
    /// Bytes received on the control connection that are not a whole line yet.
    private var pending = Data()
    /// Set while a command whose reply must not be sent is carried out.
    private var muted = false

    /// A session for a control connection the server accepted.
    internal init(server: TestFTPServer, socket: Int32) {
        self.server = server
        self.socket = socket
    }

    /// Greets the client and answers its commands until it quits or hangs up, then closes the
    /// connection.
    internal func run() {
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
                while !server.isStopped, TestFTPServer.sendAll(socket, filler) {
                    // Sending is the work; the loop only repeats it.
                }
                break
            }
            if let long = server.options.longLineReplyTo, long.verb.uppercased() == verb {
                _ = TestFTPServer.sendAll(socket, Data(repeating: 0x78, count: long.bytes))
                while !server.isStopped { Thread.sleep(forTimeInterval: 0.05) }
                break
            }
            muted = server.options.dropReplyFor?.uppercased() == verb
            let command = Command(verb: verb, argument: parts.count > 1 ? String(parts[1]) : "")
            if !handle(command) || muted { break }
        }
        if let passive { close(passive) }
        server.closed(socket)
    }

    /// Sends a reply line (or several, joined by CRLF); nothing while the reply is to be dropped.
    internal func reply(_ text: String) {
        if muted {
            return
        }
        _ = TestFTPServer.sendAll(socket, Data((text + "\r\n").utf8))
    }

    /// The real path of a path the client named; nil when it would leave the served folder.
    internal func local(_ path: String) -> URL? {
        let combined = path.hasPrefix("/") ? path : directory + "/" + path
        var names: [Substring] = []
        for name in combined.split(separator: "/") {
            if name == ".." { _ = names.popLast() } else if name != "." { names.append(name) }
        }
        return names.isEmpty ? server.root : server.root.appendingPathComponent(names.joined(separator: "/"))
    }

    /// The path the client sees for a real path in the served folder.
    internal func virtual(_ url: URL) -> String {
        let path = String(url.path.dropFirst(server.root.path.count))
        return path.isEmpty ? "/" : path
    }

    /// True when `url` is a folder (a link to one counts).
    internal func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The next line of the control connection without its line end; nil once the client hung up.
    private func readLine() -> String? {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            if let end = pending.firstIndex(of: 0x0A) {
                var line = pending[pending.startIndex..<end]
                if line.last == 0x0D { line = line.dropLast() }
                // Bytes that are no UTF-8 are taken one by one, as Latin-1 has a character for each.
                let text = String(bytes: line, encoding: .utf8) ?? String(bytes: line, encoding: .isoLatin1) ?? ""
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

    /// Carries out one command; false when the session is to end (QUIT).
    private func handle(_ command: Command) -> Bool {
        if command.verb == "QUIT" {
            reply("221 Bye")
            return false
        }
        if let step = Self.beforeLogin[command.verb] {
            step(self, command)
        } else if !loggedIn {
            reply("530 Please log in")
        } else if let step = Self.afterLogin[command.verb] {
            step(self, command)
        } else {
            reply("500 Unknown command")
        }
        return true
    }

    deinit {
        // Nothing to release: `run` closes the sockets.
    }
}
