import AFMKernel
internal import Foundation

/// Reading directories, and where their links lead.
extension FTPConnection {
    /// What a listing has read so far: the lines cut from the data, the entries handed on, the links held
    /// back, and whether the receiver still wants more.
    internal struct ListingReader {
        /// Whether the lines are MLSD's; else they are LIST's.
        internal let asMLSD: Bool
        /// How the connection reads and writes names.
        internal let encoding: NameEncoding
        /// Where names that must be written back as they came are kept (the session's).
        internal let names: NameMemory
        /// Cuts the data into lines.
        internal var splitter = LineSplitter(limit: FTPLimits.lineLength)
        /// Links are held back: whether one leads to a directory is asked when the listing is through.
        internal var links: [RemoteEntry] = []
        /// False once the receiver said it wants no more.
        internal var wanted = true
        /// The entries read so far.
        internal var entries = 0
        /// The bytes read so far.
        internal var bytes: Int64 = 0

        /// Takes one block of the data connection; throws when the listing grows beyond `FTPLimits`.
        internal mutating func take(_ block: Data, receive: ([RemoteEntry]) -> Bool) throws {
            bytes += Int64(block.count)
            guard bytes <= FTPLimits.listingBytes, entries <= FTPLimits.listingEntries else {
                throw NetworkError.unexpected(
                    "a directory listing of more than \(FTPLimits.listingEntries) entries or "
                        + "\(FTPLimits.listingBytes >> 20) MB"
                )
            }
            deliver(splitter.feed(block), receive: receive)
        }

        /// Hands on the entries of some lines, apart from the links, and remembers the names that must be
        /// written back as they came.
        internal mutating func deliver(_ lines: [Data], receive: ([RemoteEntry]) -> Bool) {
            let sending = encoding.sending
            // Lines that were read in another encoding than names are written in, apart.
            var foreign: [(text: String, encoding: String.Encoding)] = []
            let texts = lines.map { line -> String in
                let read = encoding.decodeTelling(line)
                if read.encoding != sending { foreign.append(read) }
                return read.text
            }
            let found = FTPListParser.entries(of: texts, asMLSD: asMLSD)
            for entry in found where NameMemory.needsRemembering(entry.name, readAs: sending, sending: sending) {
                names.remember(entry.name, encoding: sending)
            }
            for line in foreign {
                if let entry = asMLSD ? FTPListParser.mlsd(line.text) : FTPListParser.list(line.text) {
                    names.remember(entry.name, encoding: line.encoding)
                }
            }
            entries += found.count
            links += found.filter(\.isSymlink)
            let plain = found.filter { !$0.isSymlink }
            if !plain.isEmpty { wanted = receive(plain) }
        }
    }

    /// Reads a directory: with MLSD where the server offers it, else with LIST (`-la` when
    /// hidden files are wanted). `receive` gets the entries piece by piece and returns false
    /// to stop.
    internal func list(
        _ path: String,
        showHidden: Bool,
        cancellation: CancellationFlag?,
        receive: ([RemoteEntry]) -> Bool
    ) throws {
        let directory = RemotePath.normalized(path)
        unresolvedLinks = []
        let (channel, asMLSD) = try openListing(directory, showHidden: showHidden, cancellation: cancellation)
        var reader = ListingReader(asMLSD: asMLSD, encoding: encoding, names: knownNames)
        do {
            while reader.wanted,
                let block = try channel.read(
                    upToCount: 256 * 1_024,
                    timeout: config.timeout,
                    cancellation: cancellation
                )
            {
                onActivity?()
                try reader.take(block, receive: receive)
            }
        } catch {
            stopTransfer(cancellation: cancellation)
            throw error
        }
        guard reader.wanted else {
            stopTransfer(cancellation: cancellation)
            return
        }
        if let rest = reader.splitter.finish() { reader.deliver([rest], receive: receive) }
        if reader.splitter.dropped > 0 {
            log?(
                "\(reader.splitter.dropped) lines of the listing were longer than \(FTPLimits.lineLength) bytes "
                    + "and were left out."
            )
        }
        try finishTransfer(cancellation: cancellation)
        guard reader.wanted, !reader.links.isEmpty, cancellation?.isCancelled != true else {
            return
        }
        _ = receive(resolveLinks(reader.links, in: directory, cancellation: cancellation))
    }

    /// Where the link at `full` leads; nil when the connection broke meanwhile.
    internal func probeLink(_ full: String, cancellation: CancellationFlag?) -> LinkMemory.Target? {
        var isDirectory = false
        if offers("MLST"), let target = try? status(of: full, cancellation: cancellation), !target.isSymlink {
            isDirectory = target.isDirectory
        } else if isUsable {
            isDirectory = (try? changeDirectory(full, cancellation: cancellation)) != nil
        }
        guard isUsable else {
            return nil
        }
        return isDirectory ? .directory : .nonDirectory
    }

    /// Starts the transfer of a listing: MLSD when it is to be used, else LIST in the directory.
    ///
    /// Also
    /// tells whether the listing is MLSD.
    private func openListing(
        _ directory: String,
        showHidden: Bool,
        cancellation: CancellationFlag?
    ) throws -> (NetStream, isMLSD: Bool) {
        if config.listing == .mlsd || (config.listing == .automatic && offersMLSD) {
            do {
                let channel = try beginTransfer(
                    "MLSD \(directory)",
                    type: "I",
                    restartAt: 0,
                    cancellation: cancellation
                )
                return (channel, true)
            } catch NetworkError.refused(let reply) where isMissingMLSD(reply) {
                // Announced but not there: LIST from now on.
                features["MLSD"] = nil
                features["MLST"] = nil
            }
        }
        // LIST with a path trips over names with spaces and leading dashes on many servers.
        try changeDirectory(directory, cancellation: cancellation)
        let channel = try beginTransfer(
            showHidden ? "LIST -la" : "LIST",
            type: "A",
            restartAt: 0,
            cancellation: cancellation
        )
        return (channel, false)
    }

    /// Whether a refused MLSD says the command is not there, on a server whose features announced it:
    /// LIST is used instead, unless the user insisted on MLSD.
    private func isMissingMLSD(_ reply: FTPReply) -> Bool {
        config.listing == .automatic && [500, 502, 504].contains(reply.code)
    }

    /// Whether a link leads to a directory is not in a LIST; each answer costs a round trip, so
    /// what the target's spelling or an earlier question settles is not asked, MLST is used where
    /// the server has it (it does not move the working directory), and a long list of links
    /// is only asked through for a short while.
    private func resolveLinks(
        _ links: [RemoteEntry],
        in path: String,
        cancellation: CancellationFlag?
    ) -> [RemoteEntry] {
        let deadline = Date().addingTimeInterval(Self.linkBudget)
        var asked = 0
        return links.map { link in
            var resolved = link
            let full = RemotePath.join(path, link.name)
            if let known = knownLinks.target(of: full) {
                resolved.isDirectory = known == .directory
            } else if link.linkTarget?.hasSuffix("/") == true {
                resolved.isDirectory = true
            } else if asked < Self.resolvedLinks, Date() < deadline, isUsable, cancellation?.isCancelled != true {
                asked += 1
                if let target = probeLink(full, cancellation: cancellation) {
                    resolved.isDirectory = target == .directory
                    knownLinks.remember(full, target: target)
                }
            } else {
                unresolvedLinks.append(full)
            }
            return resolved
        }
    }
}
