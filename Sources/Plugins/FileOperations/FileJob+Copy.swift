import AFMContracts
import AFMKernel
import Foundation
import os

extension FileJob {
    /// True when the item has been copied for a move and its source is still to be removed.
    internal func execute(_ plan: Plan, _ item: FileItem, _ flight: Flight) throws -> Bool {
        let removesSource: Bool
        switch plan {
        case .write(let destination, let replacing):
            removesSource = try put(item, at: destination, replacing: replacing, flight)
            record(isMove ? .move : .copy, item.url, destination, .done)

        case .rename(let destination):
            // The file under another spelling of its own name. Only a rename can do that; a
            // copy would be written over the file and the move would then remove it. (Both are
            // places of the disk: the planner takes the file system of what it finds there.)
            let from = try fileSystems.provider(for: item.url)
            do {
                try from.move(item.url, to: destination, replacing: true, cancellation: cancellation)
            } catch FileSystemError.crossesVolumes {
                throw FileJobError.copyToItself
            }
            record(.move, item.url, destination, .done)
            return false

        case .append(let destination):
            removesSource = try extend(destination, with: item, resuming: false, flight)
            record(.append, item.url, destination, .done)

        case .resume(let destination):
            removesSource = try extend(destination, with: item, resuming: true, flight)
            record(isMove ? .move : .copy, item.url, destination, .done)
        }
        return removesSource
    }

    /// Brings one file or link to `destination`, by the cheapest way that works.
    ///
    /// True when it was copied for a move: the caller removes the source, as a step that can be
    /// retried.
    private func put(_ item: FileItem, at destination: URL, replacing: Bool, _ flight: Flight) throws -> Bool {
        let (from, to) = (try fileSystems.provider(for: item.url), try fileSystems.provider(for: destination))
        try ensureFolder(destination.deletingLastPathComponent(), in: to)
        if isMove, from === to {
            do {
                try from.move(item.url, to: destination, replacing: replacing, cancellation: cancellation)
                return false
            } catch FileSystemError.crossesVolumes {}
        }
        // From here on the file is read and written anew, which must never happen onto the file
        // itself: the copy would take the source's place, and a move would then remove it.
        if isStillTheSource(destination, of: item.url) { throw FileJobError.copyToItself }
        // A pipe or a device is not read: there is nothing in it to copy, and opening it may
        // never return. A link to one is still copied where links are copied as links.
        if item.isSpecial || FileIdentity.isSpecialNode(item.url, followingLinks: true) {
            let copiesLink = from === to && !followsLinks && (item.isSymlink || FileIdentity.isSymlink(item.url))
            if !copiesLink { throw FileJobError.specialFile(display(item.url)) }
        }
        // The copy is written under a temporary name next to the target and renamed when it is
        // complete: a failed or interrupted copy never damages an existing file and never
        // leaves a partial one under the real name.
        let temporary = temporaryName(next: destination)
        do {
            try copyContents(of: item, to: temporary, from: from, to: to, flight)
            if options.verifies { try verify(temporary, against: item.url) }
            try to.move(temporary, to: destination, replacing: replacing, cancellation: cancellation)
        } catch {
            // What arrived of a stream can be kept for Resume, when that was asked for.
            let tidying = patience(with: to)
            if options.keepsPartialFiles, !replacing, !(error is FileJobError),
                let left = to.item(at: temporary, cancellation: tidying),
                left.size > 0, !left.isSymlink,
                (try? to.move(temporary, to: destination, replacing: false, cancellation: tidying)) != nil
            {
                flight.partial = (destination, left.size)
                throw error
            }
            discard(temporary, in: to)
            throw error
        }
        return isMove
    }

    /// True when `target` is the very file `source` is, as far as that can be known: the same
    /// place once every view is seen through, or the same file on a local disk.
    ///
    /// What was written there is then not a second copy, and the source must stay.
    internal func isStillTheSource(_ target: URL, of source: URL) -> Bool {
        let (there, here) = (
            RealLocation.resolve(target, in: fileSystems), RealLocation.resolve(source, in: fileSystems)
        )
        return there.isSameLocation(as: here) || FileIdentity.sameFile(there, here)
    }

    /// Takes away the partial file an earlier try of this flight left under the real name, if
    /// it is still that file.
    ///
    /// Nothing that was there before the job is ever touched by this.
    internal func removePartial(of flight: Flight) {
        guard let partial = flight.partial else {
            return
        }
        flight.partial = nil
        guard let provider = try? fileSystems.provider(for: partial.url),
            let left = provider.item(at: partial.url, cancellation: cancellation),
            !left.isDirectory, !left.isSymlink, left.size == partial.size
        else { return }
        try? provider.remove(partial.url, cancellation: cancellation)
    }

    /// Removes the temporary file of a failed transfer.
    ///
    /// A copy of a locked file is locked too, and the system refuses to remove or rename such a
    /// file; it is unlocked the way a locked item is when the user agrees to delete it
    /// (`removing`), and removed again.
    internal func discard(_ temporary: URL, in provider: any FileSystemProvider) {
        // Tidying up: the job may be stopped already, which must not keep the file from going.
        let tidying = patience(with: provider)
        do {
            try provider.remove(temporary, cancellation: tidying)
            return
        } catch  where Self.isRefusedAsLocked(error) {
            // Never a link: the change of permissions would land on what it points to.
            if let left = provider.item(at: temporary, cancellation: tidying), !left.isSymlink {
                try? provider.setAttributes(
                    FileAttributes(permissions: left.permissions | 0o200),
                    of: temporary,
                    cancellation: tidying
                )
                if (try? provider.remove(temporary, cancellation: tidying)) != nil {
                    return
                }
            }
        } catch {}
        // Still there (a job that is being stopped does not ask): the user hears of it.
        if !isStopping, provider.item(at: temporary, cancellation: cancellation) != nil {
            note(.delete, at: temporary, "This temporary file of an interrupted copy could not be removed.")
        }
    }

    internal func temporaryName(next destination: URL) -> URL {
        destination.deletingLastPathComponent().appending(name: ".afm-\(UUID().uuidString).tmp")
    }

    /// Copies to a free name.
    ///
    /// A cancelled or failed copy within one file system leaves nothing behind; of a stream the
    /// caller removes what arrived.
    private func copyContents(
        of item: FileItem,
        to destination: URL,
        from: any FileSystemProvider,
        to: any FileSystemProvider,
        _ flight: Flight
    ) throws {
        // A link that is followed is read through, which only a stream does.
        // (A link that was not followed, because it leads back into its own folder, comes
        // here as the link it is and is copied as one.)
        let followed = try followsLinks && !item.isSymlink && entry(at: item.url)?.isSymlink == true
        if from === to, !followed {
            do {
                // With the job's flag: a copy the file system makes in one piece (a clone, a
                // copy on a server) never asks how far it is, and ends with the job all the same.
                try from.copy(item.url, to: destination, cancellation: cancellation) { copied in
                    self.advance(flight, to: copied)
                    return !self.isStopping
                }
                if !options.preservesAttributes, !item.isSymlink {
                    try? to.setAttributes(
                        FileAttributes(modified: Date(), permissions: 0o644),
                        of: destination,
                        cancellation: cancellation
                    )
                }
                return
            } catch FileSystemError.crossesVolumes {
                // The file system cannot copy between these two places itself; stream instead.
            } catch {
                throw isStopping ? Cancelled() : error
            }
        }
        // Between two file systems the contents are read from one and written to the other.
        let reader = try from.read(item.url, cancellation: cancellation)
        defer { reader.close() }
        let writer = try to.write(destination, cancellation: cancellation)
        // A read or write that waits for a server ends when the job is cancelled or aborted.
        let tokens = interrupting(reader) + interrupting(writer)
        defer { withExtendedLifetime(tokens) {} }
        do {
            try stream(reader, into: writer, flight, alreadyCopied: 0)
            try writer.close(attributes: attributes(for: item, from: from, to: to))
        } catch {
            try? writer.close(attributes: FileAttributes())
            throw error
        }
        if let origin = flight.origin { mark(destination, with: origin, in: to, shownAs: item.url) }
        // A followed link is streamed within one file system, which loses what copying would
        // have kept: tags, flags, creation date. They come from what the link points to.
        if followed, from === to, options.preservesAttributes, item.url.isFileURL {
            try? to.copyMetadata(from: item.url.resolvingSymlinksInPath(), to: destination, cancellation: cancellation)
        }
    }

    /// Ties a stream to the job's two stop signals: while the returned objects live, a cancel
    /// or an abort ends a read or write of `reader` that waits.
    internal func interrupting(_ reader: any FileReader) -> [AnyObject] {
        [cancellation.interrupting(reader), stop.interrupting(reader)]
    }

    internal func interrupting(_ writer: any FileWriter) -> [AnyObject] {
        [cancellation.interrupting(writer), stop.interrupting(writer)]
    }

    /// What a streamed copy gets.
    ///
    /// Rights that come from another file system (an archive, a server) were chosen by somebody
    /// else: set-user-ID, set-group-ID and the sticky bit never come along, and on the local disk
    /// the rest is cut by the user's umask, the way `tar` and `unzip` unpack.
    internal func attributes(for item: FileItem, from: any FileSystemProvider, to: any FileSystemProvider)
        -> FileAttributes
    {
        guard options.preservesAttributes else {
            return FileAttributes()
        }
        var permissions = item.permissions
        if from !== to {
            permissions &= 0o777
            if to.scheme == "file" { permissions &= ~Self.umask }
        }
        return FileAttributes(modified: item.modified, permissions: permissions)
    }

    /// Puts the origin mark on what was copied.
    ///
    /// A file system that cannot keep marks does nothing; one that can and fails says so, and the
    /// user hears of it: the copy is there, but without the mark that it came from elsewhere.
    internal func mark(_ url: URL, with origin: Data, in provider: any FileSystemProvider, shownAs shown: URL) {
        do {
            try provider.setQuarantine(origin, of: url, cancellation: cancellation)
        } catch {
            if !isStopping {
                note(
                    .copy,
                    at: shown,
                    "The copy could not be marked as coming from elsewhere: \(error.localizedDescription)"
                )
            }
        }
    }

    /// Every block lives in a pool of its own: the buffers a reader hands out are otherwise
    /// kept until the thread ends, which for a job is after its last file.
    internal func stream(_ reader: any FileReader, into writer: any FileWriter, _ flight: Flight, alreadyCopied: Int64)
        throws
    {
        var copied = alreadyCopied
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let block = try reader.read(upToCount: 1 << 20) else {
                return false
            }
            try checkCancelled()
            try writer.write(block)
            copied += Int64(block.count)
            advance(flight, to: copied)
            return true
        }) {}
    }
}
