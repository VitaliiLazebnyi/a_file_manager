import AFMKernel
import Foundation

/// Making folders, writing, removing, moving, copying and changing attributes.
///
/// Each change also comes with a `cancellation`: the wait for an archive that is being opened
/// (or fetched from a server) ends when it is set, and a place outside the archive hands the
/// flag on to the file system it belongs to.
extension ArchiveFileSystem {
    /// Makes a folder in an archive (kept back until the archive is written), or outside one.
    internal func createDirectory(at url: URL) throws {
        try makeDirectory(at: url, cancellation: nil)
    }

    /// The same with the caller's flag.
    internal func createDirectory(at url: URL, cancellation: CancellationFlag) throws {
        try makeDirectory(at: url, cancellation: cancellation)
    }

    /// Runs a change.
    ///
    /// The store may let an archive go between handing it out and the change (its file was
    /// replaced, or it was the least recently used): the archive then refuses the change, and the
    /// change is made in the archive the store has now. So a change never lands in an archive that
    /// nobody will write.
    private func changing<T>(attempts: Int = 8, _ body: () throws -> T) throws -> T {
        do { return try body() } catch ArchiveError.retired where attempts > 0 {
            return try changing(attempts: attempts - 1, body)
        }
    }

    private func makeDirectory(at url: URL, cancellation: CancellationFlag?) throws {
        try changing {
            switch try resolve(url, cancellation: cancellation) {
            case .outside(let provider, let outer):
                if let cancellation {
                    try provider.createDirectory(at: outer, cancellation: cancellation)
                } else {
                    try provider.createDirectory(at: outer)
                }

            case .inside(let archive, let path, _):
                try Self.check(cancellation)
                try archive.makeDirectory(path)
            }
        }
    }

    /// A writer of a new member at `url` (it replaces one of that name), or of a file outside the archive.
    internal func write(_ url: URL) throws -> any FileWriter {
        try changing {
            switch try resolve(url, cancellation: nil) {
            case .outside(let provider, let outer):
                return try provider.write(outer)

            case .inside(let archive, let path, _):
                return try archive.write(path, level: nil, password: nil)
            }
        }
    }

    /// The same with the caller's flag.
    internal func write(_ url: URL, cancellation: CancellationFlag) throws -> any FileWriter {
        try changing {
            switch try resolve(url, cancellation: cancellation) {
            case .outside(let provider, let outer):
                return try provider.write(outer, cancellation: cancellation)

            case .inside(let archive, let path, _):
                if cancellation.isCancelled { throw ArchiveError.cancelled }
                return try archive.write(path, level: nil, password: nil)
            }
        }
    }

    /// A place outside the archive may allow it; a member of an archive cannot be continued.
    internal func append(to url: URL, at offset: Int64?, cancellation: CancellationFlag) throws -> any FileWriter {
        switch try resolve(url, cancellation: cancellation) {
        case .outside(let provider, let outer):
            return try provider.append(to: outer, at: offset, cancellation: cancellation)

        case .inside:
            throw FileSystemError.notSupported("Continuing a file inside an archive")
        }
    }

    /// Removes a member or an empty folder from an archive (kept back until the archive is
    /// written), or a place outside one.
    internal func remove(_ url: URL) throws {
        try removing(url, cancellation: nil)
    }

    /// The same with the caller's flag.
    internal func remove(_ url: URL, cancellation: CancellationFlag) throws {
        try removing(url, cancellation: cancellation)
    }

    private func removing(_ url: URL, cancellation: CancellationFlag?) throws {
        try changing {
            switch try resolve(url, cancellation: cancellation) {
            case .outside(let provider, let outer):
                if let cancellation {
                    try provider.remove(outer, cancellation: cancellation)
                } else {
                    try provider.remove(outer)
                }

            case .inside(let archive, let path, _):
                try Self.check(cancellation)
                try archive.remove(path)
            }
        }
    }

    /// Whether two places are in the same archive, or both outside one: only then can this
    /// file system move or copy between them itself.
    ///
    /// Decided from the URLs, before any archive is opened.
    private func requireSameVolume(_ source: URL, _ destination: URL) throws {
        switch (ArchiveURL.parse(source), ArchiveURL.parse(destination)) {
        case (.inside(let from), .inside(let target)) where from.archive.isSameLocation(as: target.archive):
            return

        case (.outside, .outside):
            return

        default:
            throw FileSystemError.crossesVolumes
        }
    }

    /// Moves or renames within one archive, or within the file system outside it; anything
    /// else throws `FileSystemError.crossesVolumes`.
    internal func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try moving(source, to: destination, replacing: replacing, cancellation: nil)
    }

    /// The same with the caller's flag.
    internal func move(_ source: URL, to destination: URL, replacing: Bool, cancellation: CancellationFlag) throws {
        try moving(source, to: destination, replacing: replacing, cancellation: cancellation)
    }

    private func moving(_ source: URL, to destination: URL, replacing: Bool, cancellation: CancellationFlag?) throws {
        try requireSameVolume(source, destination)
        try changing {
            switch (
                try resolve(source, cancellation: cancellation), try resolve(destination, cancellation: cancellation)
            ) {
            case (.outside(let provider, let from), .outside(let other, let target)) where provider === other:
                if let cancellation {
                    try provider.move(from, to: target, replacing: replacing, cancellation: cancellation)
                } else {
                    try provider.move(from, to: target, replacing: replacing)
                }

            case (.inside(let archive, let from, _), .inside(let other, let target, _)) where archive === other:
                try Self.check(cancellation)
                try archive.move(from, to: target, replacing: replacing)

            case (.inside, .inside):
                // The archive was read anew between the two look-ups.
                throw ArchiveError.retired

            default:
                throw FileSystemError.crossesVolumes
            }
        }
    }

    /// Copies within one ZIP archive, or within the file system outside it; anything else
    /// throws `FileSystemError.crossesVolumes`.
    internal func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try requireSameVolume(source, destination)
        try changing {
            switch (try resolve(source, cancellation: nil), try resolve(destination, cancellation: nil)) {
            case (.outside(let provider, let from), .outside(let other, let target)) where provider === other:
                try provider.copy(from, to: target, progress: progress)

            case (.inside(let archive, let from, _), .inside(let other, let target, _))
            where archive === other && archive.format.isEditable:
                _ = progress(try archive.duplicate(from, to: target))

            default:
                throw FileSystemError.crossesVolumes
            }
        }
    }

    /// The same with the caller's flag, which a place outside the archive is handed on to:
    /// its file system can then end a copy that waits.
    internal func copy(_ source: URL, to destination: URL, cancellation: CancellationFlag, progress: (Int64) -> Bool)
        throws
    {
        try Self.check(cancellation)
        try requireSameVolume(source, destination)
        try changing {
            switch (
                try resolve(source, cancellation: cancellation), try resolve(destination, cancellation: cancellation)
            ) {
            case (.outside(let provider, let from), .outside(let other, let target)) where provider === other:
                try provider.copy(from, to: target, cancellation: cancellation, progress: progress)

            case (.inside(let archive, let from, _), .inside(let other, let target, _))
            where archive === other && archive.format.isEditable:
                _ = progress(try archive.duplicate(from, to: target))

            default:
                throw FileSystemError.crossesVolumes
            }
        }
    }

    /// Changes the date or the permissions of a member (kept back until the archive is
    /// written), or of a place outside the archive.
    internal func setAttributes(_ attributes: FileAttributes, of url: URL) throws {
        try settingAttributes(attributes, of: url, cancellation: nil)
    }

    /// The same with the caller's flag.
    internal func setAttributes(_ attributes: FileAttributes, of url: URL, cancellation: CancellationFlag) throws {
        try settingAttributes(attributes, of: url, cancellation: cancellation)
    }

    private func settingAttributes(_ attributes: FileAttributes, of url: URL, cancellation: CancellationFlag?) throws {
        try changing {
            switch try resolve(url, cancellation: cancellation) {
            case .outside(let provider, let outer):
                if let cancellation {
                    try provider.setAttributes(attributes, of: outer, cancellation: cancellation)
                } else {
                    try provider.setAttributes(attributes, of: outer)
                }

            case .inside(let archive, let path, _):
                try Self.check(cancellation)
                try archive.setAttributes(attributes, of: path)
            }
        }
    }
}
