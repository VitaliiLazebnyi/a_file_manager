import AFMContracts
import AFMKernel
import Foundation
import os

extension FileJob {
    /// Append and Resume: the file at the target followed by the source (all of it, or what
    /// the target lacks), written next to the target and swapped in when it is complete.
    ///
    /// The existing part is written again; in return the target stays whole until the longer file
    /// has fully arrived. A Resume on a file system that can continue a file (`.append`) does not
    /// copy the partial file at all: it is the file that grows, after a check that it really is the
    /// start of the source. An Append always takes the safe way.
    internal func extend(_ destination: URL, with item: FileItem, resuming: Bool, _ flight: Flight) throws -> Bool {
        let (from, to) = (try fileSystems.provider(for: item.url), try fileSystems.provider(for: destination))
        // Looked at again here, right before the files are opened: only a plain file is
        // continued. A link would be read and written through to what it points to, and a
        // pipe on either side would never answer.
        guard let existing = try entry(at: destination) else { throw FileJobError.sourceMissing(display(destination)) }
        guard isPlainFile(existing) else { throw FileJobError.notPlainFile(display(destination)) }
        if item.isSpecial || FileIdentity.isSpecialNode(item.url, followingLinks: true) {
            throw FileJobError.specialFile(display(item.url))
        }
        if isStillTheSource(destination, of: item.url) { throw FileJobError.copyToItself }
        if resuming, to.capabilities(for: destination).contains(.append) {
            do {
                return try resumeInPlace(destination, partial: existing, with: item, from: from, to: to, flight)
            } catch FileSystemError.notSupported {
                // The file system cannot continue this one after all: write it anew.
            }
        }
        let temporary = temporaryName(next: destination)
        let writer = try to.write(temporary, cancellation: cancellation)
        let writerTokens = interrupting(writer)
        defer { withExtendedLifetime(writerTokens) {} }
        do {
            let head = try to.read(destination, cancellation: cancellation)
            defer { head.close() }
            let headTokens = interrupting(head)
            defer { withExtendedLifetime(headTokens) {} }
            var kept: Int64 = 0
            while try autoreleasepool(invoking: { () throws -> Bool in
                guard let block = try head.read(upToCount: 1 << 20) else {
                    return false
                }
                try checkCancelled()
                try writer.write(block)
                kept += Int64(block.count)
                return true
            }) {}
            let reader = try from.read(item.url, cancellation: cancellation)
            defer { reader.close() }
            let readerTokens = interrupting(reader)
            defer { withExtendedLifetime(readerTokens) {} }
            if resuming {
                // The same check as when the file is continued in place: its end (all of it
                // when the job verifies) must be the source's, or the two do not belong together.
                guard kept < item.size,
                    try startsWithPartial(reader, destination, in: to, length: kept, fully: options.verifies, flight)
                else {
                    throw FileJobError.cannotResume(display(destination))
                }
                try reader.seek(to: UInt64(kept))
            }
            try stream(reader, into: writer, flight, alreadyCopied: resuming ? kept : 0)
            // A resumed file is the source and gets its date; an appended one is new now.
            try writer.close(
                attributes: resuming
                    ? attributes(for: item, from: from, to: to) : FileAttributes(permissions: existing.permissions)
            )
            if let origin = flight.origin { mark(temporary, with: origin, in: to, shownAs: item.url) }
            if resuming, options.verifies { try verify(temporary, against: item.url) }
            // The longer file is a new one: tags, comments, access rules and the date of
            // creation of the old one come along, last of all (a lock among them forbids the rest).
            try? to.copyMetadata(from: destination, to: temporary, cancellation: cancellation)
            // Tags and flags of the old file have come along; the mark of where the added
            // part came from must still be on the new one.
            if let origin = flight.origin, to.quarantine(of: temporary) == nil {
                mark(temporary, with: origin, in: to, shownAs: item.url)
            }
            try to.move(temporary, to: destination, replacing: true, cancellation: cancellation)
        } catch {
            try? writer.close(attributes: FileAttributes())
            discard(temporary, in: to)
            throw error
        }
        return isMove
    }

    /// Resume by continuing the partial file where it ends.
    ///
    /// The partial is first compared with the start of the source: its last block (up to 1 MB), or
    /// all of it when the job verifies, since a file that is not the start of the source would be
    /// joined to the wrong rest. A failed or cancelled continuation leaves the file as long as it
    /// got, as any partial file is.
    private func resumeInPlace(
        _ destination: URL,
        partial: FileItem,
        with item: FileItem,
        from: any FileSystemProvider,
        to: any FileSystemProvider,
        _ flight: Flight
    ) throws -> Bool {
        let kept = partial.size
        let reader = try from.read(item.url, cancellation: cancellation)
        defer { reader.close() }
        let readerTokens = interrupting(reader)
        defer { withExtendedLifetime(readerTokens) {} }
        guard try startsWithPartial(reader, destination, in: to, length: kept, fully: options.verifies, flight) else {
            throw FileJobError.cannotResume(display(destination))
        }
        let writer = try to.append(to: destination, at: kept, cancellation: cancellation)
        let writerTokens = interrupting(writer)
        defer { withExtendedLifetime(writerTokens) {} }
        do {
            advance(flight, to: kept)
            try stream(reader, into: writer, flight, alreadyCopied: kept)
            try writer.close(attributes: attributes(for: item, from: from, to: to))
        } catch {
            try? writer.close(attributes: FileAttributes())
            throw error
        }
        if let origin = flight.origin { mark(destination, with: origin, in: to, shownAs: item.url) }
        if options.verifies {
            do {
                try verify(destination, against: item.url)
            } catch {
                // What was added is taken off again, so that the file is the partial one it was.
                if let undo = try? to.append(to: destination, at: kept, cancellation: patience(with: to)) {
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
    /// Without `fully` only the last block is compared.
    private func startsWithPartial(
        _ reader: any FileReader,
        _ partial: URL,
        in provider: any FileSystemProvider,
        length: Int64,
        fully: Bool,
        _ flight: Flight
    ) throws -> Bool {
        let head = try provider.read(partial, cancellation: cancellation)
        defer { head.close() }
        let headTokens = interrupting(head)
        defer { withExtendedLifetime(headTokens) {} }
        let block: Int64 = 1 << 20
        var position = fully ? 0 : max(0, length - block)
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
                try Checksum.sha256(
                    of: url,
                    in: self.fileSystems,
                    flags: [self.cancellation, self.stop],
                    isCancelled: {
                        self.emit(force: false)
                        return self.isStopping
                    }
                )
            }
        }
        let (original, written) = (try digests[0].get(), try digests[1].get())
        guard let original, let written else { throw Cancelled() }
        if original != written { throw FileJobError.verifyFailed(display(source)) }
    }
}
