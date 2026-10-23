import AFMKernel
import Foundation

/// New members, written through writers.
extension OpenArchive {
    /// Where a new member waits until it is written into the archive.
    internal struct Spool {
        /// The temporary file of the member.
        internal let url: URL
        /// The folder it lies in, whose room is watched.
        internal let folder: URL
        /// Whether that is a folder of the archive's own next to it, not the temporary folder.
        internal let isOutside: Bool
    }

    /// Where the next new member waits until it is written into the archive: in the
    /// temporary folder, or, when the archive lies on another volume than that folder, in a
    /// hidden folder next to the archive.
    ///
    /// A job that copies a hundred gigabytes into a ZIP on an external disk then needs the room
    /// there, where the archive grows anyway, and not on the disk the system runs from. Asks the
    /// disk, so it is called without the lock.
    private func newSpool() throws -> Spool {
        var place = locked { spoolFolder.map { folder in (folder: folder, isOutside: spoolIsOutside) } }
        if place == nil {
            let scratch = environment.scratch.url
            let home = localURL.deletingLastPathComponent()
            var chosen = (folder: scratch, isOutside: false)
            if fetchedCopy == nil, let own = environment.volume(home.path),
                let other = environment.volume(scratch.deletingLastPathComponent().path), own != other
            {
                let folder = home.appendingPathComponent(".afm-spool-\(getpid())-\(instance)", isDirectory: true)
                if mkdir(folder.path, 0o700) == 0 || errno == EEXIST {
                    environment.scratch.noteExternal(folder)
                    chosen = (folder, true)
                }
            }
            // Two writers that began together decided the same: the folder's name is the archive's.
            place = locked {
                if spoolFolder == nil { (spoolFolder, spoolIsOutside) = (chosen.folder, chosen.isOutside) }
                return spoolFolder.map { folder in (folder: folder, isOutside: spoolIsOutside) }
            }
        }
        guard let place, place.isOutside else {
            return Spool(
                url: try environment.scratch.newFile("zipdata"),
                folder: environment.scratch.url,
                isOutside: false
            )
        }
        return Spool(
            url: place.folder.appendingPathComponent(UUID().uuidString + ".zipdata", isDirectory: false),
            folder: place.folder,
            isOutside: true
        )
    }

    /// Starts a new member.
    ///
    /// Its data is compressed into a temporary file while it is written and joins the archive's
    /// directory when the writer is closed. `level` overrides the compression rate of the settings;
    /// with a `password` the member is encrypted (AES-256).
    internal func write(_ path: String, level: Int?, password: String?) throws -> any FileWriter {
        try requireWritable()
        try locked {
            try requireEditable()
            guard !path.isEmpty else { throw ArchiveError.notFound(path) }
            if tree.entry(path) != nil { throw FileSystemError.alreadyExists(path) }
            let parent = ArchiveTree.parent(of: path)
            guard tree.isDirectory(parent) || tree.entry(parent) == nil else {
                throw ArchiveError.notADirectory(parent)
            }
            // From here on the archive is in use: it is not let go while the file is made.
            openWriters += 1
        }
        // The temporary file is made without the lock.
        do {
            let spool = try newSpool()
            // The room is watched while a large member comes in, wherever it waits.
            let room = SpaceWatch(
                folder: spool.folder,
                reserve: spool.isOutside ? 64 << 20 : environment.scratchReserve,
                step: 32 << 20,
                hasRoom: environment.hasRoom
            )
            return try ZipMemberWriter(
                archive: self,
                path: path,
                level: level ?? environment.options.compressionLevel,
                password: password?.isEmpty == false ? password : nil,
                spool: spool.url,
                room: room
            )
        } catch {
            try? finishWrite(nil, path: path)
            throw error
        }
    }

    /// The end of a writer: with a record the member joins the directory.
    ///
    /// That is refused when the disk has no room to write the member into the archive file later:
    /// the writer fails here, where its job can still tell the user and keep the source.
    internal func finishWrite(_ record: ZipRecord?, path: String) throws {
        guard let record else {
            // Abandoned: nothing joins. What else waits is written once no writer is open.
            locked {
                openWriters -= 1
                if openWriters == 0, hasPendingLocked, let delay = environment.flushDelay {
                    armTimer(after: idleDelay(delay))
                }
            }
            return
        }
        // The disk is asked without the lock.
        let needed: UInt64 = locked {
            let directory = file.size - min(file.size, directoryOffset)
            let copied = writesWholeArchive ? file.size : 0
            let members = pendingBytes.plusClamped(record.compressedSize)
            return copied.plusClamped(members).plusClamped(directory + 4_096)
        }
        let fits = environment.hasRoom(needed, localURL.deletingLastPathComponent())
        try locked {
            openWriters -= 1
            guard fits else {
                if openWriters == 0, hasPendingLocked, let delay = environment.flushDelay {
                    armTimer(after: idleDelay(delay))
                }
                throw ArchiveError.noRoom(name)
            }
            // Something else took the name meanwhile: the member that was finished last stays.
            if let existing = tree.entry(path), !existing.isImplicit { take(existing) }
            var arriving = record
            arriving.unwritten.insert(.arriving)
            put(Self.entry(path: path, for: arriving), keepingOrder: false)
            pendingBytes = pendingBytes.plusClamped(record.compressedSize)
            arrivedBytes = arrivedBytes.plusClamped(record.compressedSize)
            changed()
        }
    }
}
