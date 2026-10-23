import AFMKernel
internal import Foundation

/// The commands that change or ask about one entry on the server.
extension FTPConnection {
    /// Checks that the server still answers.
    ///
    /// A connection that a router dropped silently does not answer at all, so the wait is short.
    internal func isAlive(cancellation: CancellationFlag?) -> Bool {
        guard isUsable else {
            return false
        }
        let reply = try? send("NOOP", shown: "NOOP", replyWithin: min(config.timeout, 5), cancellation: cancellation)
        return reply?.isSuccess ?? false
    }

    /// Makes `path` the server's working directory, unless it is that already.
    internal func changeDirectory(_ path: String, cancellation: CancellationFlag?) throws {
        let directory = RemotePath.normalized(path)
        if workingDirectory == directory {
            return
        }
        workingDirectory = nil
        try perform("CWD \(directory)", cancellation: cancellation)
        workingDirectory = directory
    }

    /// Creates a directory (MKD).
    internal func makeDirectory(_ path: String, cancellation: CancellationFlag?) throws {
        knownLinks.forgetAll()
        try perform("MKD \(path)", cancellation: cancellation)
    }

    /// Removes an empty directory (RMD), first leaving it when the server stands in it.
    internal func removeDirectory(_ path: String, cancellation: CancellationFlag?) throws {
        knownLinks.forgetAll()
        // Some servers refuse to remove the directory they stand in.
        if let current = workingDirectory, current == path || current.hasPrefix(path + "/") {
            try? changeDirectory("/", cancellation: cancellation)
        }
        try perform("RMD \(path)", cancellation: cancellation)
    }

    /// Deletes a file (DELE).
    internal func deleteFile(_ path: String, cancellation: CancellationFlag?) throws {
        knownLinks.forgetAll()
        try perform("DELE \(path)", cancellation: cancellation)
    }

    /// Renames or moves an entry (RNFR, then RNTO).
    internal func rename(_ source: String, to destination: String, cancellation: CancellationFlag?) throws {
        knownLinks.forgetAll()
        let from = try send("RNFR \(source)", cancellation: cancellation)
        guard from.isIntermediate else { throw NetworkError.refused(from) }
        try perform("RNTO \(destination)", cancellation: cancellation)
        workingDirectory = nil
    }

    /// The size of a file in bytes; nil when the server does not tell (a directory, or no SIZE).
    internal func size(of path: String, cancellation: CancellationFlag?) throws -> Int64? {
        try setType("I", cancellation: cancellation)
        let reply = try send("SIZE \(path)", cancellation: cancellation)
        return reply.code == 213 ? Int64(reply.text.trimmingCharacters(in: .whitespaces)) : nil
    }

    /// The time of the last change of a file (MDTM); nil when the server does not tell.
    internal func modificationTime(of path: String, cancellation: CancellationFlag?) throws -> Date? {
        let reply = try send("MDTM \(path)", cancellation: cancellation)
        return reply.code == 213 ? FTPSyntax.time(reply.text.trimmingCharacters(in: .whitespaces)) : nil
    }

    /// The entry at a path through MLST; nil when nothing is there.
    internal func status(of path: String, cancellation: CancellationFlag?) throws -> RemoteEntry? {
        let reply = try send("MLST \(path)", cancellation: cancellation)
        guard reply.code == 250 else {
            if reply.code / 100 == 5, reply.code != 550 { throw NetworkError.refused(reply) }
            return nil
        }
        return reply.lines.dropFirst().dropLast().lazy.compactMap(FTPListParser.mlst).first
    }

    /// Sets the time of last change with MFMT, where the server offers it.
    internal func setModificationTime(_ date: Date, of path: String, cancellation: CancellationFlag?) throws {
        guard offers("MFMT") else { throw FileSystemError.notSupported("Changing the date on this server") }
        try perform("MFMT \(FTPSyntax.timeText(date)) \(path)", cancellation: cancellation)
    }

    /// Sets the Unix permission bits with SITE CHMOD.
    internal func setPermissions(_ permissions: UInt16, of path: String, cancellation: CancellationFlag?) throws {
        try perform("SITE CHMOD \(String(permissions & 0o7777, radix: 8)) \(path)", cancellation: cancellation)
    }
}
