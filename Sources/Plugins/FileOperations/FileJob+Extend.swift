import AFMKernel
import Foundation

/// Append, Resume and Verify.
extension FileJob {
    /// Append and Resume: the file at the target followed by the source (all of it, or what
    /// the target lacks), written next to the target and swapped in when it is complete.
    ///
    /// The existing part is written again; in return the target stays whole until the longer file
    /// has fully arrived. A Resume on a file system that can continue a file (`.append`) does not
    /// copy the partial file at all: it is the file that grows, after a check that it really is the
    /// start of the source. An Append always takes the safe way.
    internal func extend(_ destination: URL, with item: FileItem, resuming: Bool, _ flight: Flight) throws -> Bool {
        let onto = try fileSystems.provider(for: destination)
        let existing = try continuable(destination, with: item)
        if resuming, onto.capabilities(for: destination).contains(.append) {
            do {
                return try resumeInPlace(destination, partial: existing, with: item, flight)
            } catch FileSystemError.notSupported {
                // The file system cannot continue this one after all: write it anew.
            }
        }
        try rewrite(destination, existing, with: item, resuming: resuming, flight)
        return isMove
    }

    /// The file at `destination`, looked at again right before the files are opened: only a plain
    /// file is continued, and only from a source that is not a pipe or a device and not the file itself.
    ///
    /// A link would be read and written through to what it points to, and a pipe on either side
    /// would never answer.
    private func continuable(_ destination: URL, with item: FileItem) throws -> FileItem {
        guard let existing = try entry(at: destination) else { throw FileJobError.sourceMissing(display(destination)) }
        guard isPlainFile(existing) else { throw FileJobError.notPlainFile(display(destination)) }
        if item.isSpecial || FileIdentity.isSpecialNode(item.url, followingLinks: true) {
            throw FileJobError.specialFile(display(item.url))
        }
        if isStillTheSource(destination, of: item.url) { throw FileJobError.copyToItself }
        return existing
    }

    /// Writes the longer file next to `destination` (the file there, then the source or the rest
    /// of it) and swaps it in when it is complete; a failed try leaves the old file as it was.
    private func rewrite(
        _ destination: URL,
        _ existing: FileItem,
        with item: FileItem,
        resuming: Bool,
        _ flight: Flight
    ) throws {
        let (from, onto) = (try fileSystems.provider(for: item.url), try fileSystems.provider(for: destination))
        let temporary = temporaryName(next: destination)
        let writer = try onto.write(temporary, cancellation: cancellation)
        let writerTokens = interrupting(writer)
        defer { keepArmed(writerTokens) }
        do {
            let kept = try copyHead(of: destination, in: onto, into: writer)
            let reader = try from.read(item.url, cancellation: cancellation)
            defer { reader.close() }
            let readerTokens = interrupting(reader)
            defer { keepArmed(readerTokens) }
            if resuming {
                // The same check as when the file is continued in place: its end (all of it
                // when the job verifies) must be the source's, or the two do not belong together.
                guard kept < item.size, try startsWithPartial(reader, destination, in: onto, length: kept, flight)
                else {
                    throw FileJobError.cannotResume(display(destination))
                }
                try reader.seek(to: UInt64(kept))
            }
            try stream(reader, into: writer, flight, alreadyCopied: resuming ? kept : 0)
            // A resumed file is the source and gets its date; an appended one is new now.
            try writer.close(
                attributes: resuming
                    ? attributes(for: item, from: from, to: onto) : FileAttributes(permissions: existing.permissions)
            )
            if let origin = flight.origin { mark(temporary, with: origin, in: onto, shownAs: item.url) }
            if resuming, options.verifies { try verify(temporary, against: item.url) }
            try swapIn(temporary, for: destination, from: item, in: onto, flight)
        } catch {
            try? writer.close(attributes: FileAttributes())
            discard(temporary, in: onto)
            throw error
        }
    }

    /// Copies the file at `destination` into `writer`; returns how many bytes it had.
    private func copyHead(of destination: URL, in provider: any FileSystemProvider, into writer: any FileWriter)
        throws -> Int64
    {
        let head = try provider.read(destination, cancellation: cancellation)
        defer { head.close() }
        let headTokens = interrupting(head)
        defer { keepArmed(headTokens) }
        var kept: Int64 = 0
        var more = true
        while more {
            more = try autoreleasepool { () throws -> Bool in
                guard let block = try head.read(upToCount: 1 << 20) else {
                    return false
                }
                try checkCancelled()
                try writer.write(block)
                kept += Int64(block.count)
                return true
            }
        }
        return kept
    }

    /// Puts the longer file written next to `destination` in its place, with the old file's
    /// metadata and the mark of where the added part came from.
    private func swapIn(
        _ temporary: URL,
        for destination: URL,
        from item: FileItem,
        in onto: any FileSystemProvider,
        _ flight: Flight
    ) throws {
        // The longer file is a new one: tags, comments, access rules and the date of
        // creation of the old one come along, last of all (a lock among them forbids the rest).
        try? onto.copyMetadata(from: destination, to: temporary, cancellation: cancellation)
        // Tags and flags of the old file have come along; the mark of where the added
        // part came from must still be on the new one.
        if let origin = flight.origin, onto.quarantine(of: temporary) == nil {
            mark(temporary, with: origin, in: onto, shownAs: item.url)
        }
        try onto.move(temporary, to: destination, replacing: true, cancellation: cancellation)
    }

    /// Resume by continuing the partial file where it ends.
    ///
    /// The partial is first compared with the start of the source: its last block (up to 1 MB), or
    /// all of it when the job verifies, since a file that is not the start of the source would be
    /// joined to the wrong rest. A failed or cancelled continuation leaves the file as long as it
    /// got, as any partial file is.
    private func resumeInPlace(_ destination: URL, partial: FileItem, with item: FileItem, _ flight: Flight) throws
        -> Bool
    {
        let (from, onto) = (try fileSystems.provider(for: item.url), try fileSystems.provider(for: destination))
        let kept = partial.size
        let reader = try from.read(item.url, cancellation: cancellation)
        defer { reader.close() }
        let readerTokens = interrupting(reader)
        defer { keepArmed(readerTokens) }
        guard try startsWithPartial(reader, destination, in: onto, length: kept, flight) else {
            throw FileJobError.cannotResume(display(destination))
        }
        let writer = try onto.append(to: destination, at: kept, cancellation: cancellation)
        let writerTokens = interrupting(writer)
        defer { keepArmed(writerTokens) }
        do {
            advance(flight, to: kept)
            try stream(reader, into: writer, flight, alreadyCopied: kept)
            try writer.close(attributes: attributes(for: item, from: from, to: onto))
        } catch {
            try? writer.close(attributes: FileAttributes())
            throw error
        }
        if let origin = flight.origin { mark(destination, with: origin, in: onto, shownAs: item.url) }
        if options.verifies {
            do {
                try verify(destination, against: item.url)
            } catch {
                // What was added is taken off again, so that the file is the partial one it was.
                if let undo = try? onto.append(to: destination, at: kept, cancellation: patience(with: onto)) {
                    try? undo.close(attributes: FileAttributes())
                }
                throw error
            }
        }
        return isMove
    }

    /// Whether the first `length` bytes of `partial` are the first bytes of the source, which
    /// `reader` is then left at the end of.
    ///
    /// Only the last block is compared, unless the job verifies.
    private func startsWithPartial(
        _ reader: any FileReader,
        _ partial: URL,
        in provider: any FileSystemProvider,
        length: Int64,
        _ flight: Flight
    ) throws -> Bool {
        let head = try provider.read(partial, cancellation: cancellation)
        defer { head.close() }
        let headTokens = interrupting(head)
        defer { keepArmed(headTokens) }
        let block: Int64 = 1 << 20
        var position = options.verifies ? 0 : max(0, length - block)
        try head.seek(to: UInt64(position))
        try reader.seek(to: UInt64(position))
        while position < length {
            try checkCancelled()
            let count = Int(min(block, length - position))
            let same = try autoreleasepool { () throws -> Bool in
                guard let mine = try Self.read(count, from: head),
                    let theirs = try Self.read(count, from: reader)
                else { return false }
                return mine == theirs
            }
            guard same else {
                return false
            }
            position += Int64(count)
            advance(flight, to: position)
        }
        return true
    }

    /// Reads the copy and the source again, each on its own core, and compares their checksums.
    ///
    /// Every block read shows the job's progress again, which is also where Pause takes hold.
    internal func verify(_ copy: URL, against source: URL) throws {
        report(["Verifying: \(display(source))"])
        let digests = Parallel.map([source, copy]) { url in
            Result {
                try Checksum.sha256(of: url, in: self.fileSystems, flags: [self.cancellation, self.stop]) {
                    self.emit(force: false)
                    return self.isStopping
                }
            }
        }
        let (original, written) = (try digests[0].get(), try digests[1].get())
        guard let original, let written else { throw Cancelled() }
        if original != written { throw FileJobError.verifyFailed(display(source)) }
    }
}
