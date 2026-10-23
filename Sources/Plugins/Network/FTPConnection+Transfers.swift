import AFMKernel
internal import Foundation

/// The data connections: setting one up for a transfer, and ending the transfer.
extension FTPConnection {
    /// The data connection of a transfer while it is set up: one this program opens (passive
    /// mode), or a port the server is to connect to (active mode).
    private enum DataSide {
        /// Passive mode: the stream this program opened to the server.
        case connecting(NetStream)
        /// Active mode: the port the server is to connect to.
        case listening(DataListener)
    }

    /// Whether the reply is a server's complaint that a data connection did not resume the TLS
    /// session of the control connection (vsftpd `require_ssl_reuse`, ProFTPD, FileZilla Server).
    internal static func requiresSessionReuse(_ reply: FTPReply) -> Bool {
        guard [421, 425, 426, 450, 522, 522, 550].contains(reply.code) else {
            return false
        }
        let text = reply.text.lowercased()
        let mentionsSession = text.contains("session") || text.contains("reuse") || text.contains("re-use")
        let says =
            text.contains("reuse") || text.contains("re-use") || text.contains("resum") || text.contains("cached")
            || text.contains("same")
        return mentionsSession && says
    }

    /// Starts a transfer: `RETR`, `STOR`, `LIST` and the like, from byte `offset` on (REST) when it is not 0.
    ///
    /// The returned stream carries the data; `finishTransfer` or `abortTransfer` must follow.
    internal func beginTransfer(
        _ command: String,
        type: Character,
        restartAt offset: UInt64,
        cancellation: CancellationFlag?
    ) throws -> NetStream {
        guard data == nil else { throw NetworkError.unexpected("A transfer is still running on this connection.") }
        try setType(type, cancellation: cancellation)
        let side = try openData(cancellation: cancellation)
        do {
            if offset > 0 {
                let rest = try send("REST \(offset)", cancellation: cancellation)
                guard rest.isIntermediate else { throw NetworkError.refused(rest) }
            }
            let reply = try send(command, cancellation: cancellation)
            guard reply.isPreliminary else { throw refusal(reply, otherwise: nil) }
            // From here on the server owes a second reply. Whatever goes wrong before the data
            // connection stands, that reply is read, or the connection is not used again: left
            // unread, it would be taken for the answer to the next command.
            var channel: NetStream?
            do {
                let opened: NetStream
                switch side {
                case .connecting(let stream):
                    opened = stream

                case .listening(let listener):
                    opened = try listener.accept(timeout: config.timeout, cancellation: cancellation)
                }
                channel = opened
                try opened.waitUntilReady(timeout: config.timeout, cancellation: cancellation)
                setStreams(control: control, data: opened)
                return opened
            } catch {
                // The command is under way; the server ends it when the data connection fails.
                channel?.close()
                cancel(side)
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
            cancel(side)
            throw error
        }
    }

    /// Ends a transfer whose data went through completely, and reads the server's verdict.
    internal func finishTransfer(cancellation: CancellationFlag?) throws {
        guard let channel = data else {
            return
        }
        // After a plain upload the end was already announced, and the data connection stays
        // open until the server has confirmed the file. An encrypted one announces its end
        // by closing (see `NetStream.finishWriting`).
        let isUpload = channel.didFinishWriting && !channel.isEncrypted
        if !isUpload { channel.close() }
        defer { channel.close() }
        setStreams(control: control, data: nil)
        var reply = try readReply(timeout: config.timeout, cancellation: cancellation)
        // Some servers announce the transfer twice (`125`, then `150`); the verdict is the
        // first reply that is not another announcement.
        var announcements = 0
        while reply.isPreliminary {
            announcements += 1
            guard announcements <= 4 else {
                isBroken = true
                throw NetworkError.unexpected(reply.message)
            }
            reply = try readReply(timeout: config.timeout, cancellation: cancellation)
        }
        lastUsed = clock()
        guard reply.isSuccess else { throw refusal(reply, otherwise: nil) }
    }

    /// Drops a transfer without asking the server about it, for a server that is not answering:
    /// the connection cannot be used again.
    internal func abandonTransfer() {
        guard let channel = data else {
            return
        }
        channel.close()
        setStreams(control: control, data: nil)
        isBroken = true
    }

    /// Ends a transfer early.
    ///
    /// The server answers the broken data connection with one reply (426 or 226); when it does not,
    /// the connection is not used again.
    internal func abortTransfer() {
        guard let channel = data else {
            return
        }
        channel.close()
        setStreams(control: control, data: nil)
        guard !isBroken, let controlStream = control else {
            return
        }
        if (try? readReply(timeout: min(config.timeout, 10), cancellation: nil)) == nil {
            isBroken = true
            return
        }
        // A server that also confirms the abort sends a second reply right away. One that keeps
        // sending replies is not listened to for long.
        var extra = 0
        while controlStream.hasInput(within: 0.05) {
            extra += 1
            if extra > 3 || (try? readReply(timeout: 2, cancellation: nil)) == nil {
                isBroken = true
                return
            }
        }
        lastUsed = clock()
    }

    /// Ends a transfer that is stopped early: abandoned when the user cancelled (the server is not
    /// waited for), else aborted.
    internal func stopTransfer(cancellation: CancellationFlag?) {
        if cancellation?.isCancelled == true {
            abandonTransfer()
        } else {
            abortTransfer()
        }
    }

    /// Opens the data connection for the next transfer command, without waiting for it: with
    /// TLS the handshake only happens once the server has seen the command.
    private func openData(cancellation: CancellationFlag?) throws -> DataSide {
        let controlStream = try stream()
        // Encrypted data connections cannot be accepted, so TLS always goes the passive way.
        guard config.passive || protectsData else {
            return try listen(on: controlStream, cancellation: cancellation)
        }
        let security: NetStream.Security = protectsData ? .tls(TLSSettings(host: config.host, trust: trust)) : .plain
        // The same machine the control connection reached: the name may lead to another one on
        // a second lookup (round-robin DNS, IPv4 against IPv6). It stays the name that the
        // certificate is checked for. Only a connection that is gone (or one through a proxy)
        // knows no address.
        let server = controlStream.remoteAddress ?? config.host
        var extendedPort: Int?
        if !extendedPassiveFailed {
            let reply = try send("EPSV", cancellation: cancellation)
            extendedPort = reply.code == 229 ? FTPSyntax.extendedPassivePort(reply.text) : nil
            if extendedPort == nil { extendedPassiveFailed = true }
        }
        let port: Int
        if let extendedPort {
            port = extendedPort
        } else {
            let reply = try send("PASV", cancellation: cancellation)
            guard reply.code == 227, let endpoint = FTPSyntax.passiveEndpoint(reply.text) else {
                throw NetworkError.refused(reply)
            }
            // The address in the reply is often a private one behind a router; the data
            // connection goes to the host the control connection reached.
            port = endpoint.port
        }
        let stream = NetStream(host: server, port: port, security: security)
        stream.start()
        return .connecting(stream)
    }

    /// Active mode: a port for the server to connect to, announced with PORT or EPRT.
    private func listen(on controlStream: NetStream, cancellation: CancellationFlag?) throws -> DataSide {
        // Only the machine the control connection reached may open the data connection. Both
        // addresses are known while the control connection is up.
        guard let peer = controlStream.remoteAddress, let address = controlStream.localAddress else {
            throw NetworkError.connectionFailed("The addresses of the control connection are unknown.")
        }
        let listener = try DataListener(peer: peer, local: address)
        let port = try listener.start(timeout: config.timeout)
        if let argument = FTPSyntax.portArgument(host: address, port: port) {
            try perform("PORT \(argument)", cancellation: cancellation)
        } else {
            try perform(
                "EPRT \(FTPSyntax.extendedPortArgument(host: address, port: port))",
                cancellation: cancellation
            )
        }
        return .listening(listener)
    }

    /// Gives a data connection up before it was used.
    private func cancel(_ side: DataSide) {
        switch side {
        case .connecting(let stream):
            stream.close()

        case .listening(let listener):
            listener.cancel()
        }
    }

    /// The error for a reply that refused a command (`otherwise` when there is one, else `refused`);
    /// a server that insists on TLS session reuse on the data connections gets its own, so the user is
    /// told what is wrong.
    private func refusal(_ reply: FTPReply, otherwise: (any Error)?) -> any Error {
        if protectsData, Self.requiresSessionReuse(reply) {
            return NetworkError.sessionReuseRequired(reply.message)
        }
        return otherwise ?? NetworkError.refused(reply)
    }
}
