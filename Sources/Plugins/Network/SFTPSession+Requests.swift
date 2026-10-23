import AFMKernel
import Foundation

/// The requests about directories and entries: listing, looking up, and the four calls that
/// change something.
extension SFTPSession {
    /// Opens a file or directory and returns the server's handle for it; `build` writes the
    /// request's arguments.
    internal func openHandle(
        _ type: SFTPRequest,
        on channel: SFTPChannel,
        cancellation: CancellationFlag?,
        _ build: (inout SFTPEncoder) -> Void
    ) throws -> Data {
        var decoder = try channel.request(type, timeout: timeout, cancellation: cancellation, build).expect(.handle)
        return Data(try decoder.bytes())
    }

    /// Closes a handle whose closing can tell nothing (it was read from, or its transfer was
    /// given up).
    ///
    /// Never waits: the request is put in line and reaches the server before whatever is asked
    /// next, so a file whose handle is closed here can be removed right after.
    internal func closeHandle(_ handle: Data, on channel: SFTPChannel) {
        channel.sendWithoutAnswer(.close) { $0.bytes(handle) }
    }

    /// Lists a directory in the batches the server sends; links are asked where they lead.
    ///
    /// The server shows hidden entries anyway, so `showHidden` changes nothing.
    internal func list(
        _ path: String,
        showHidden _: Bool,
        cancellation: CancellationFlag?,
        receive: ([RemoteEntry]) -> Bool
    )
        throws
    {
        try perform(cancellation: cancellation) { channel in
            let handle = try openHandle(.opendir, on: channel, cancellation: cancellation) { $0.string(path) }
            defer { closeHandle(handle, on: channel) }
            var wanted = true
            while wanted {
                let packet = try channel.request(.readdir, timeout: timeout, cancellation: cancellation) { encoder in
                    encoder.bytes(handle)
                }
                if packet.statusCode == SFTPError.endOfFile { break }
                var entries = try decodeEntries(in: packet)
                try resolveLinks(in: &entries, of: path, on: channel, cancellation: cancellation)
                wanted = entries.isEmpty || receive(entries)
            }
        }
    }

    /// The entry at a path; nil when nothing is there.
    ///
    /// A link says whether it leads to a directory; one whose target cannot be read is a link to a file.
    internal func entry(at path: String, cancellation: CancellationFlag?) throws -> RemoteEntry? {
        let normalized = RemotePath.normalized(path)
        return try perform(cancellation: cancellation) { channel in
            guard
                let attributes = try attributes(
                    of: normalized,
                    following: false,
                    on: channel,
                    cancellation: cancellation
                )
            else { return nil }
            var entry = attributes.entry(named: normalized == "/" ? "/" : RemotePath.name(of: normalized))
            if entry.isSymlink {
                do {
                    if let target = try self.attributes(
                        of: normalized,
                        following: true,
                        on: channel,
                        cancellation: cancellation
                    ) {
                        entry.isDirectory = target.isDirectory
                    }
                } catch NetworkError.cancelled {
                    throw NetworkError.cancelled
                } catch {
                    // The target cannot be read: the link stays a link to a file.
                }
            }
            return entry
        }
    }

    // The four calls that change something end on the caller's flag and on `closing`, which
    // is set when the session is disconnected.

    /// Makes a directory with the server's usual permissions.
    internal func makeDirectory(_ path: String, cancellation: CancellationFlag?) throws {
        try withEither(closing, cancellation) { closing in
            try perform(cancellation: closing) { channel in
                try channel.request(.mkdir, timeout: timeout, cancellation: closing) { encoder in
                    encoder.string(path)
                    encoder.attributes(SFTPAttributes())
                }
                .checkStatus()
            }
        }
    }

    /// Removes a file, a link or an empty directory; what nobody knows is asked of the server first.
    internal func remove(_ path: String, kind: RemovedKind, cancellation: CancellationFlag?) throws {
        try withEither(closing, cancellation) { closing in
            try perform(cancellation: closing) { channel in
                var isFolder = kind == .directory
                if kind == .unknown {
                    isFolder =
                        try attributes(of: path, following: false, on: channel, cancellation: closing)?.isDirectory
                        ?? false
                }
                try channel.request(isFolder ? .rmdir : .remove, timeout: timeout, cancellation: closing) { encoder in
                    encoder.string(path)
                }
                .checkStatus()
            }
        }
    }

    /// With `replacing`, OpenSSH's extension is used where the server has it: it renames like
    /// the Mac does, an existing file is replaced in the same step.
    ///
    /// Without, the plain rename of the protocol, which a server refuses when the destination
    /// exists. What the server answers is thrown as it is (`SFTPError`): a refusal is not turned
    /// into "something is in the way", which only the caller can find out.
    internal func rename(_ source: String, to destination: String, replacing: Bool, cancellation: CancellationFlag?)
        throws
    {
        try withEither(closing, cancellation) { closing in
            try perform(cancellation: closing) { channel in
                if replacing, channel.extensions["posix-rename@openssh.com"] != nil {
                    try channel.request(.extended, timeout: timeout, cancellation: closing) { encoder in
                        encoder.string("posix-rename@openssh.com")
                        encoder.string(source)
                        encoder.string(destination)
                    }
                    .checkStatus()
                } else {
                    try channel.request(.rename, timeout: timeout, cancellation: closing) { encoder in
                        encoder.string(source)
                        encoder.string(destination)
                    }
                    .checkStatus()
                }
            }
        }
    }

    /// Sets the modification date and the permissions that `attributes` gives.
    internal func setAttributes(_ attributes: FileAttributes, of path: String, cancellation: CancellationFlag?) throws {
        var changes = SFTPAttributes()
        changes.modified = attributes.modified.map { UInt32(clamping: Int64($0.timeIntervalSince1970)) }
        changes.permissions = attributes.permissions.map { UInt32($0 & 0o7777) }
        try withEither(closing, cancellation) { closing in
            try perform(cancellation: closing) { channel in
                try channel.request(.setstat, timeout: timeout, cancellation: closing) { encoder in
                    encoder.string(path)
                    encoder.attributes(changes)
                }
                .checkStatus()
            }
        }
    }

    /// The attributes of a path, of a link's target when `following`; nil when nothing is there.
    private func attributes(
        of path: String,
        following: Bool,
        on channel: SFTPChannel,
        cancellation: CancellationFlag?
    ) throws -> SFTPAttributes? {
        let request: SFTPRequest = following ? .stat : .lstat
        let packet = try channel.request(request, timeout: timeout, cancellation: cancellation) { $0.string(path) }
        if packet.statusCode == SFTPError.noSuchFile {
            return nil
        }
        var decoder = try packet.expect(.attributes)
        return try decoder.attributes()
    }

    /// The entries of one answer to a listing, names that may not become paths left out.
    private func decodeEntries(in packet: SFTPPacket) throws -> [RemoteEntry] {
        var decoder = try packet.expect(.name)
        var entries: [RemoteEntry] = []
        for _ in 0..<(try decoder.u32()) {
            let name = try decoder.name()
            _ = try decoder.bytes()
            let attributes = try decoder.attributes()
            guard RemoteEntry.isSafeName(name.text) else { continue }
            if NameMemory.needsRemembering(name.text, readAs: name.encoding, sending: .utf8) {
                names.remember(name.text, encoding: name.encoding)
            }
            entries.append(attributes.entry(named: name.text))
        }
        return entries
    }

    /// Asks where the links of a batch lead and marks those that lead to a directory.
    ///
    /// The questions go out for all links at once, and all the answers together get the time one
    /// answer may take; a link whose target cannot be read stays a link to a file.
    private func resolveLinks(
        in entries: inout [RemoteEntry],
        of path: String,
        on channel: SFTPChannel,
        cancellation: CancellationFlag?
    ) throws {
        let links = entries.indices.filter { entries[$0].isSymlink }
        let targets = links.map { RemotePath.join(path, entries[$0].name) }
        var answers: [SFTPChannel.Ticket] = []
        do {
            for target in targets {
                answers.append(try channel.send(.stat, cancellation: cancellation) { $0.string(target) })
            }
        } catch {
            // The requests that did go out are not waited for any more.
            answers.forEach(channel.abandon)
            throw error
        }
        let deadline = Date().addingTimeInterval(timeout)
        for (position, (index, answer)) in zip(links, answers).enumerated() {
            do {
                let left = max(0.05, deadline.timeIntervalSinceNow)
                var target = try channel.wait(for: answer, timeout: left, cancellation: cancellation)
                    .expect(.attributes)
                entries[index].isDirectory = try target.attributes().isDirectory
            } catch NetworkError.cancelled {
                answers[position...].forEach(channel.abandon)
                throw NetworkError.cancelled
            } catch NetworkError.connectionLost {
                answers[position...].forEach(channel.abandon)
                throw NetworkError.connectionLost
            } catch {
                // The target cannot be read: the link stays a link to a file.
            }
        }
    }
}
