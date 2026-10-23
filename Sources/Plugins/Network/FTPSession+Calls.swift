import AFMKernel
import Foundation

/// The calls of `RemoteSession`, each on a connection of the pool.
extension FTPSession {
    /// Connects if necessary and returns the directory the login leads to.
    internal func connect(cancellation: CancellationFlag?) throws -> String {
        _ = try command(repeatable: true, cancellation: cancellation) { _ in
            // A connection of the pool, logged in, is all that is wanted.
        }
        condition.lock()
        defer { condition.unlock() }
        return home
    }

    /// Returns at once: the connections in use are cut, every wait of the session ends, and
    /// the goodbye to the server on the idle ones is said in the background.
    internal func disconnect() {
        condition.lock()
        isClosed = true
        let (resting, busy, tested) = (idle, Array(inUse.values), pinged)
        idle = []
        total -= resting.count
        pendingLinks = []
        keepAlive?.cancel()
        keepAlive = nil
        condition.broadcast()
        condition.unlock()
        closing.cancel()
        for connection in busy {
            connection.interrupt()
        }
        tested?.interrupt()
        if !resting.isEmpty {
            Background.run(lane: self) {
                for connection in resting {
                    connection.close()
                }
            }
        }
    }

    /// Lists a directory, handing the entries to `receive` in batches until it returns false; the links
    /// the listing had no time for are asked about in the background.
    internal func list(
        _ path: String,
        showHidden: Bool,
        cancellation: CancellationFlag?,
        receive: ([RemoteEntry]) -> Bool
    ) throws {
        var delivered = false
        var unresolved: [String] = []
        _ = try perform(
            transfer: nil,
            cancellation: cancellation,
            mayRetry: { _ in !delivered },
            work: { connection in
                try connection.list(path, showHidden: showHidden, cancellation: cancellation) { entries in
                    delivered = true
                    return receive(entries)
                }
                unresolved = connection.unresolvedLinks
            }
        )
        if !unresolved.isEmpty, cancellation?.isCancelled != true { resolveLinksLater(unresolved) }
    }

    /// The entry at a path; nil when nothing is there.
    ///
    /// MLST where the server has it, else SIZE, MDTM and CWD, else the listing of the parent.
    internal func entry(at path: String, cancellation: CancellationFlag?) throws -> RemoteEntry? {
        let normalized = RemotePath.normalized(path)
        guard let parent = RemotePath.parent(of: normalized) else {
            return RemoteEntry(name: "/", isDirectory: true)
        }
        return try command(repeatable: true, cancellation: cancellation) { connection in
            if connection.offers("MLST") {
                return try connection.status(of: normalized, cancellation: cancellation)
            }
            let name = RemotePath.name(of: normalized)
            if connection.offers("SIZE") {
                if let size = try connection.size(of: normalized, cancellation: cancellation) {
                    let modified =
                        connection.offers("MDTM")
                        ? try connection.modificationTime(of: normalized, cancellation: cancellation) : nil
                    return RemoteEntry(name: name, isDirectory: false, size: size, modified: modified)
                }
                if (try? connection.changeDirectory(normalized, cancellation: cancellation)) != nil {
                    return RemoteEntry(name: name, isDirectory: true)
                }
                // Neither a file whose size the server tells nor a directory to enter: the listing decides.
            }
            var found: RemoteEntry?
            try connection.list(parent, showHidden: true, cancellation: cancellation) { entries in
                found = entries.first { $0.name == name }
                return found == nil
            }
            return found
        }
    }

    // The four calls that change something end on the caller's flag, on `closing` when the
    // session is disconnected, and by the limits of `acquire`.

    /// Creates a directory.
    internal func makeDirectory(_ path: String, cancellation: CancellationFlag?) throws {
        try withEither(closing, cancellation) { closing in
            try command(repeatable: false, cancellation: closing) { connection in
                try connection.makeDirectory(path, cancellation: closing)
            }
        }
    }

    /// Removes a file or an empty directory; `kind` says which, when it is known.
    internal func remove(_ path: String, kind: RemovedKind, cancellation: CancellationFlag?) throws {
        try withEither(closing, cancellation) { closing in try remove(path, kind: kind, ending: closing) }
    }

    /// FTP has one rename, and what it does to an existing destination is the server's choice.
    internal func rename(_ source: String, to destination: String, replacing _: Bool, cancellation: CancellationFlag?)
        throws
    {
        try withEither(closing, cancellation) { closing in
            try command(repeatable: false, cancellation: closing) { connection in
                try connection.rename(source, to: destination, cancellation: closing)
            }
        }
    }

    /// Sets the date (MFMT) and the permissions (SITE CHMOD) that `attributes` gives.
    internal func setAttributes(_ attributes: FileAttributes, of path: String, cancellation: CancellationFlag?) throws {
        try withEither(closing, cancellation) { closing in
            try command(repeatable: true, cancellation: closing) { connection in
                if let modified = attributes.modified {
                    try connection.setModificationTime(modified, of: path, cancellation: closing)
                }
                if let permissions = attributes.permissions {
                    try connection.setPermissions(permissions, of: path, cancellation: closing)
                }
            }
        }
    }

    /// Opens a file for reading; the transfer starts with the first read.
    internal func openRead(_ path: String, cancellation: CancellationFlag?) throws -> any FileReader {
        if cancellation?.isCancelled == true { throw NetworkError.cancelled }
        return FTPReader(
            session: self,
            path: RemotePath.normalized(path),
            asText: environment.options.transfersAsText(RemotePath.name(of: path))
        )
    }

    /// Starts writing a file that does not exist yet (STOR).
    internal func openWrite(_ path: String, cancellation: CancellationFlag?) throws -> any FileWriter {
        let normalized = RemotePath.normalized(path)
        let asText = environment.options.transfersAsText(RemotePath.name(of: normalized))
        let (stream, connection) = try transfer(.write, cancellation: cancellation) { connection in
            try connection.beginTransfer(
                "STOR \(normalized)",
                type: asText ? "A" : "I",
                restartAt: 0,
                cancellation: cancellation
            )
        }
        return FTPWriter(
            session: self,
            connection: connection,
            stream: stream,
            path: normalized,
            asText: asText,
            start: 0
        )
    }

    /// Continuing needs a transfer in binary, so that the offsets are those of the file on the server.
    internal func canAppend(_ path: String) -> Bool {
        guard !environment.options.transfersAsText(RemotePath.name(of: path)) else {
            return false
        }
        condition.lock()
        defer { condition.unlock() }
        return !hasConnected || offersRestart
    }

    /// `APPE` where the file is continued at its end, else `REST` and `STOR` (RFC 3659).
    ///
    /// A server does not cut a file there, and one that does not know `APPE` may start the file
    /// anew, so the length is checked when the file is closed, as after every upload.
    internal func openAppend(_ path: String, at offset: Int64?, cancellation: CancellationFlag?) throws -> (
        writer: any FileWriter, size: Int64
    ) {
        let normalized = RemotePath.normalized(path)
        if environment.options.transfersAsText(RemotePath.name(of: normalized)) {
            throw FileSystemError.notSupported("Continuing a transfer in text mode")
        }
        let size = try currentSize(of: normalized, cancellation: cancellation)
        let target = offset ?? size
        guard target >= 0, target <= size else {
            throw FileSystemError.notSupported("Continuing \(normalized) at \(target), it has \(size) bytes")
        }
        let (stream, connection) = try transfer(.write, cancellation: cancellation) { connection in
            guard target == size || connection.offers("REST") else {
                throw FileSystemError.notSupported("Continuing a file on this server")
            }
            return try connection.beginTransfer(
                target == size ? "APPE \(normalized)" : "STOR \(normalized)",
                type: "I",
                restartAt: target == size ? 0 : UInt64(target),
                cancellation: cancellation
            )
        }
        let writer = FTPWriter(
            session: self,
            connection: connection,
            stream: stream,
            path: normalized,
            asText: false,
            start: target
        )
        return (writer, target)
    }

    /// Starts a download at `offset` on a connection of its own.
    internal func beginDownload(
        _ path: String,
        asText: Bool,
        offset: UInt64,
        cancellation: CancellationFlag?
    ) throws -> (stream: NetStream, connection: FTPConnection) {
        let (stream, connection) = try transfer(.read, cancellation: cancellation) { connection in
            try connection.beginTransfer(
                "RETR \(path)",
                type: asText ? "A" : "I",
                restartAt: offset,
                cancellation: cancellation
            )
        }
        return (stream, connection)
    }

    /// Date and permissions of a file that was just uploaded, as far as the server takes them.
    internal func applyAfterUpload(_ attributes: FileAttributes, to path: String, on connection: FTPConnection) {
        if let modified = attributes.modified, connection.offers("MFMT") {
            try? connection.setModificationTime(modified, of: path, cancellation: nil)
        }
        condition.lock()
        let triesChmod = !refusesChmod
        condition.unlock()
        guard let permissions = attributes.permissions, triesChmod else {
            return
        }
        do {
            try connection.setPermissions(permissions, of: path, cancellation: nil)
        } catch NetworkError.refused(let reply) where [500, 502, 504].contains(reply.code) {
            // A server without chmod is not asked for every file.
            condition.lock()
            refusesChmod = true
            condition.unlock()
        } catch {
            // Any other refusal leaves the permissions as the server set them.
        }
    }

    /// The size of an existing file: SIZE where the server has it, else what `entry` finds; throws
    /// when there is no such file.
    private func currentSize(of path: String, cancellation: CancellationFlag?) throws -> Int64 {
        let known = try command(repeatable: true, cancellation: cancellation) { connection in
            connection.offers("SIZE") ? try connection.size(of: path, cancellation: cancellation) : nil
        }
        guard
            let size = try known
                ?? entry(at: path, cancellation: cancellation).flatMap({ $0.isDirectory ? nil : $0.size })
        else {
            throw NetworkError.refused(FTPReply(code: 550, lines: ["No such file"]))
        }
        return size
    }

    /// Removes on one connection: DELE or RMD, and for an entry of unknown kind RMD after DELE was refused.
    private func remove(_ path: String, kind: RemovedKind, ending closing: CancellationFlag) throws {
        try command(repeatable: false, cancellation: closing) { connection in
            if kind == .directory {
                return try connection.removeDirectory(path, cancellation: closing)
            }
            do {
                try connection.deleteFile(path, cancellation: closing)
            } catch NetworkError.refused(let fileReply) where kind == .unknown {
                // Nobody said what it is; a directory is removed with another command.
                do {
                    try connection.removeDirectory(path, cancellation: closing)
                } catch NetworkError.refused(let directoryReply) {
                    let isFile = directoryReply.text.range(of: "not a directory", options: .caseInsensitive) != nil
                    throw NetworkError.refused(isFile ? fileReply : directoryReply)
                }
            }
        }
    }
}
