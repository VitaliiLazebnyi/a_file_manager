import Foundation

/// The commands of the login, the current directory and the data connection's address.
extension TestFTPSession {
    /// USER: takes the name; lets the client in at once when the server wants no password.
    internal func logIn(user name: String) {
        let options = server.options
        user = name
        reply(options.user == nil ? "230 Welcome" : "331 Password please")
        loggedIn = options.user == nil
    }

    /// PASS: lets the client in when the name and the password are the ones of the options.
    internal func logIn(password: String) {
        let options = server.options
        loggedIn = options.user == nil || (user == options.user && password == options.password)
        reply(loggedIn ? "230 Welcome" : "530 Login incorrect")
    }

    /// FEAT: lists the features the options offer, or refuses the command.
    internal func features() {
        let options = server.options
        guard options.offersFeatures else {
            reply("502 Not implemented")
            return
        }
        var lines = ["211-Features:", " UTF8", " MDTM", " MFMT"]
        if options.offersREST { lines.append(" REST STREAM") }
        if options.offersSize { lines.append(" SIZE") }
        if options.offersMLSD { lines += [" MLST type*;size*;modify*;UNIX.mode*;", " MLSD"] }
        if options.offersEPSV { lines.append(" EPSV") }
        lines.append("211 End")
        reply(lines.joined(separator: "\r\n"))
    }

    /// PWD: the current directory, quotes in it doubled.
    internal func printDirectory() {
        reply("257 \"\(directory.replacingOccurrences(of: "\"", with: "\"\""))\" is the current directory")
    }

    /// CWD and CDUP: moves to a folder of the served folder.
    internal func changeDirectory(to path: String) {
        guard let url = local(path), isDirectory(url) else {
            reply("550 No such directory")
            return
        }
        directory = virtual(url)
        reply("250 OK")
    }

    /// PASV and EPSV: opens a socket for the next data connection and says where it listens.
    internal func listenPassively(_ command: Command) {
        guard command.verb == "PASV" || server.options.offersEPSV else {
            reply("500 Unknown command")
            return
        }
        // Forgotten as soon as it is closed: should no new one be had, the number may soon be
        // somebody else's, and a later transfer or the end of the session would close that.
        if let old = passive {
            close(old)
            passive = nil
        }
        guard let listener = try? TestFTPServer.listen() else {
            reply("425 No port")
            return
        }
        passive = listener
        active = nil
        let port = TestFTPServer.port(of: listener)
        reply(
            command.verb == "PASV"
                ? "227 Entering Passive Mode (127,0,0,1,\(port / 256),\(port % 256))"
                : "229 Entering Extended Passive Mode (|||\(port)|)"
        )
    }

    /// PORT: notes the address `h1,h2,h3,h4,p1,p2` for the next data connection.
    internal func connectActively(port argument: String) {
        let numbers = argument.split(separator: ",").compactMap { Int($0) }
        guard numbers.count == 6 else {
            reply("501 Bad address")
            return
        }
        active = (numbers[0..<4].map(String.init).joined(separator: "."), numbers[4] * 256 + numbers[5])
        reply("200 PORT OK")
    }

    /// EPRT: notes the address `|1|host|port|` for the next data connection.
    internal func connectActively(extendedPort argument: String) {
        let fields = argument.split(separator: "|")
        guard fields.count == 3, let port = Int(fields[2]) else {
            reply("501 Bad address")
            return
        }
        active = (String(fields[1]), port)
        reply("200 EPRT OK")
    }

    /// REST: the offset the next transfer starts at (0 for what is no number).
    internal func restart(from argument: String) {
        restartOffset = UInt64(argument) ?? 0
        reply("350 Restarting at \(restartOffset)")
    }
}
