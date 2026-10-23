import AFMKernel
import Foundation

/// Opens an archive file for `ArchiveStore`: one on this disk where it lies, any other (on a
/// server, inside another archive) from a copy fetched to the temporary folder first.
///
/// Blocks for as long as the opening and the fetch take: not for the main thread.
internal struct ArchiveOpener {
    /// The settings and the temporary folder the archive is opened with.
    internal let environment: ArchiveEnvironment

    /// Opens the archive at `url`; a `cancellation` ends the opening and the fetch soon after it is set.
    internal func open(_ url: URL, cancellation: CancellationFlag?) throws -> OpenArchive {
        guard ArchiveURL.nesting(of: url) < environment.maxNesting else {
            throw ArchiveError.unsupported("An archive more than \(environment.maxNesting) archives deep")
        }
        if url.isFileURL {
            return try openLocal(url, cancellation: cancellation)
        }
        return try openFetched(url, cancellation: cancellation)
    }

    /// An archive on this disk, read where it lies.
    private func openLocal(_ url: URL, cancellation: CancellationFlag?) throws -> OpenArchive {
        var status = stat()
        guard stat(url.path, &status) == 0 else { throw posixError(errno, url.path) }
        guard status.st_mode & S_IFMT == S_IFREG else { throw ArchiveError.notAnArchive(url.lastPathComponent) }
        // Reached through a symbolic link, the archive is changed where it really lies:
        // a new file put at the link's place would leave the real one as it was.
        return try OpenArchive(
            archiveURL: url,
            localURL: Durable.realFile(url),
            fetchedCopy: nil,
            remoteStamp: nil,
            quarantine: nil,
            cancellation: cancellation,
            environment: environment
        )
    }

    /// An archive on a server or inside another archive, fetched to the disk first.
    ///
    /// Spec 08 › Nested archives. The copy is removed again when the fetch is given up.
    private func openFetched(_ url: URL, cancellation: CancellationFlag?) throws -> OpenArchive {
        guard let fileSystems = environment.fileSystems() else { throw FileSystemError.noProvider(url) }
        let flag = cancellation ?? CancellationFlag()
        let provider = try fileSystems.provider(for: url)
        guard let item = provider.item(at: url, cancellation: flag), !item.isDirectory else {
            throw flag.isCancelled ? ArchiveError.cancelled : ArchiveError.notAnArchive(url.lastPathComponent)
        }
        let copy = try fetch(url, size: item.size, from: provider, flag: flag)
        // An archive inside an archive from the internet is from the internet too, and so is
        // one fetched from a server: the copy carries the mark, and so does what is unpacked.
        let quarantine = provider.quarantine(of: url)
        Quarantine.apply(quarantine, to: copy.url)
        return try OpenArchive(
            archiveURL: url,
            localURL: copy.url,
            fetchedCopy: copy,
            remoteStamp: (item.size, item.modified),
            quarantine: quarantine,
            cancellation: cancellation,
            environment: environment
        )
    }

    /// Copies the file at `url` (`size` bytes, as its file system claims) into the temporary
    /// folder; the copy goes when the returned object goes.
    private func fetch(
        _ url: URL,
        size: Int64,
        from provider: any FileSystemProvider,
        flag: CancellationFlag
    ) throws -> TemporaryFile {
        let local = try environment.scratch.newFile(url.pathExtension.isEmpty ? "archive" : url.pathExtension)
        // Not unless the copy fits beside what must stay free; the size is what the other
        // side claims, so the room is watched while the copy grows, too.
        let scratch = environment.scratch.url
        guard environment.hasRoom(environment.scratchReserve.plusClamped(UInt64(max(0, size))), scratch) else {
            throw ArchiveError.noScratchRoom(url.lastPathComponent)
        }
        let room = SpaceWatch(
            folder: scratch,
            reserve: environment.scratchReserve,
            step: 32 << 20,
            hasRoom: environment.hasRoom
        )
        let copy = TemporaryFile(local)
        let reader = try provider.read(url, cancellation: flag)
        defer { reader.close() }
        // A read that waits on a server is ended by the flag too.
        try withExtendedLifetime(flag.interrupting(reader)) {
            let output = try OutputFile(creating: local, mode: 0o600)
            while let block = try reader.read(upToCount: 1 << 20) {
                if flag.isCancelled { throw ArchiveError.cancelled }
                guard room.allows(UInt64(block.count)) else {
                    output.discard()
                    throw ArchiveError.noScratchRoom(url.lastPathComponent)
                }
                try output.write(block)
            }
            try output.close(durably: false)
        }
        return copy
    }
}
