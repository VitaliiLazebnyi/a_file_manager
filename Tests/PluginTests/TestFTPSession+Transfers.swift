import Foundation

/// The commands that move data over a data connection: listings, downloads and uploads.
extension TestFTPSession {
    /// LIST, NLST and MLSD: sends the lines of a folder over the data connection.
    ///
    /// LIST and NLST take `ls` flags (`-a` shows hidden items) instead of a path; MLSD always
    /// shows hidden items.
    internal func list(_ command: Command) {
        let options = server.options
        let isMachine = command.verb == "MLSD"
        guard !isMachine || options.offersMLSD else {
            reply("500 Unknown command")
            return
        }
        let isFlags = command.argument.hasPrefix("-")
        let showHidden = isMachine || isFlags && command.argument.contains("a")
        let path = isMachine || !isFlags ? command.argument : ""
        guard let url = local(path), isDirectory(url) else {
            reply("550 No such directory")
            return
        }
        server.listingStarted()
        if options.listDelay > 0 {
            // In slices: a server that is stopped does not keep its thread for the whole pause.
            let end = Date().addingTimeInterval(options.listDelay)
            while !server.isStopped, Date() < end {
                Thread.sleep(forTimeInterval: min(0.05, max(0, end.timeIntervalSinceNow)))
            }
        }
        let names = ((try? fileManager.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
            .filter { name in
                showHidden || !name.hasPrefix(".")
            }
        let style: LineStyle = isMachine ? .machine : (options.dosListing ? .dos : .unix)
        let lines =
            names.map { name in
                line(for: url.appendingPathComponent(name), name: name, style: style)
            }
            + options.injectedLines
        let preamble = command.verb == "LIST" && !options.dosListing ? "total \(names.count)\r\n" : ""
        let listing = options.rawListing ?? Data((preamble + lines.map { $0 + "\r\n" }.joined()).utf8)
        transfer { TestFTPServer.sendAll($0, listing) }
        server.listingEnded()
    }

    /// RETR: sends a file from the REST offset on, or stalls or resets as the options say.
    internal func retrieve(_ path: String) {
        let options = server.options
        guard let url = local(path), !isDirectory(url), let data = try? Data(contentsOf: url) else {
            reply("550 No such file")
            return
        }
        let offset = Int(min(restartOffset, UInt64(data.count)))
        restartOffset = 0
        if options.stallRETR {
            stalled()
            return
        }
        guard let limit = options.resetRETRAfter else {
            transfer { TestFTPServer.sendAll($0, data.subdata(in: offset..<data.count)) }
            return
        }
        transfer { connection in
            _ = TestFTPServer.sendAll(connection, data.subdata(in: offset..<min(data.count, offset + limit)))
            // A reset instead of an orderly end.
            var linger = linger(l_onoff: 1, l_linger: 0)
            setsockopt(connection, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<linger>.size))
            return false
        }
    }

    /// STOR and APPE: receives a file; APPE and a REST offset continue the file that is there.
    internal func store(_ command: Command) {
        let options = server.options
        guard let url = local(command.argument), isDirectory(url.deletingLastPathComponent()), !isDirectory(url)
        else {
            reply("553 Cannot create the file")
            return
        }
        let offset = restartOffset
        restartOffset = 0
        if options.stallSTOR {
            stalled()
            return
        }
        let appends = command.verb == "APPE"
        transfer { connection in
            var received = TestFTPServer.receiveAll(connection)
            if let kept = options.keepsOfUploads { received = received.prefix(kept) }
            guard (appends && !options.appendStartsAnew) || offset > 0 else {
                return (try? received.write(to: url)) != nil
            }
            return write(received, to: url, appending: appends, at: offset)
        }
    }

    /// Writes into the file that is there: at its end, or at `offset`.
    ///
    /// Like most servers, nothing beyond the new data is cut off. False when it could not be written.
    private func write(_ data: Data, to url: URL, appending: Bool, at offset: UInt64) -> Bool {
        if !fileManager.fileExists(atPath: url.path) { fileManager.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            return false
        }
        defer { try? handle.close() }
        do {
            if appending { try handle.seekToEnd() } else { try handle.seek(toOffset: offset) }
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    /// A transfer that starts and then never sends anything, until the server stops.
    private func stalled() {
        transfer { _ in
            while !server.isStopped { Thread.sleep(forTimeInterval: 0.05) }
            return false
        }
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
}
