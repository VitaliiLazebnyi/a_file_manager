public import AFMKernel
public import Foundation

/// The calls that change something on the server.
///
/// They come in two forms: without a flag, and with the flag of the job that asks, which ends
/// every wait they make for the server (N010, N026).
extension RemoteFileSystem {
    /// Makes the folder at `url`, and the folders above it that are missing.
    public func createDirectory(at url: URL) throws {
        try createDirectory(at: url, cancellation: Optional<CancellationFlag>.none)
    }

    /// Makes the folder at `url`, and the folders above it that are missing; `cancellation` ends the waits.
    public func createDirectory(at url: URL, cancellation: CancellationFlag) throws {
        try createDirectory(at: url, cancellation: Optional(cancellation))
    }

    /// Makes the folder at `url` and the missing ones above it; a folder already there is fine, a file is not.
    private func createDirectory(at url: URL, cancellation: CancellationFlag?) throws {
        let target = try resolve(url, cancellation: cancellation)
        let (session, key, path) = (target.session, target.key, target.path)
        guard let parent = RemotePath.parent(of: path) else {
            return
        }
        if let existing = try entry(at: url, cancellation: cancellation, beforeOverwriting: false) {
            if existing.isDirectory {
                return
            }
            throw FileSystemError.alreadyExists(displayPath(url))
        }
        let parentURL = key.url(path: parent)
        if parent != "/", try entry(at: parentURL, cancellation: cancellation, beforeOverwriting: false) == nil {
            try createDirectory(at: parentURL, cancellation: cancellation)
        }
        do {
            try session.makeDirectory(path, cancellation: cancellation)
        } catch {
            cache.forget(parentURL)
            throw error
        }
        cache.insert(RemoteEntry(name: RemotePath.name(of: path), isDirectory: true, modified: Date()), in: parentURL)
    }

    /// Opens a new file at `url` for writing; throws when something is there already.
    public func write(_ url: URL) throws -> any FileWriter {
        try write(url, cancellation: Optional<CancellationFlag>.none)
    }

    /// Opens a new file at `url` for writing; throws when something is there, and `cancellation` ends the waits.
    public func write(_ url: URL, cancellation: CancellationFlag) throws -> any FileWriter {
        try write(url, cancellation: Optional(cancellation))
    }

    /// Opens a new file at `url`, whose entry the cached listing gets at once.
    private func write(_ url: URL, cancellation: CancellationFlag?) throws -> any FileWriter {
        let target = try resolve(url, cancellation: cancellation)
        if try entry(at: url, cancellation: cancellation, beforeOverwriting: true) != nil {
            throw FileSystemError.alreadyExists(displayPath(url))
        }
        let directory = parentURL(url)
        let name = RemotePath.name(of: target.path)
        let writer: any FileWriter
        do {
            writer = try target.session.openWrite(target.path, cancellation: cancellation)
        } catch {
            cache.forget(directory)
            throw error
        }
        // The file exists on the server from now on; its size and date follow when it is closed.
        cache.insert(RemoteEntry(name: name, isDirectory: false, modified: Date()), in: directory)
        return CachingWriter(writer, cache: cache, directory: directory, name: name, written: 0)
    }

    /// Continues an existing file (Resume, Append).
    ///
    /// The server has it at the new length at once, so the cached listing follows; what is written
    /// later is entered when the file is closed.
    public func append(to url: URL, at offset: Int64?, cancellation: CancellationFlag) throws -> any FileWriter {
        let target = try resolve(url, cancellation: cancellation)
        guard target.session.canAppend(target.path) else {
            throw FileSystemError.notSupported("Continuing a file on this server")
        }
        let (directory, name) = (parentURL(url), RemotePath.name(of: target.path))
        let opened: (writer: any FileWriter, size: Int64)
        do {
            opened = try target.session.openAppend(target.path, at: offset, cancellation: cancellation)
        } catch {
            cache.forget(directory)
            throw error
        }
        cache.update(name, in: directory) { entry in entry.size = opened.size }
        return CachingWriter(opened.writer, cache: cache, directory: directory, name: name, written: opened.size)
    }

    /// Where a server cannot continue a file (an FTP server without `REST`, a transfer in text
    /// mode) the capability is missing, and the caller writes the file again.
    public func capabilities(for url: URL) -> FileSystemCapabilities {
        guard let key = ServerKey(url), key.scheme == scheme, let session = center.existingSession(for: key) else {
            return capabilities
        }
        return session.canAppend(RemotePath.of(url)) ? capabilities : capabilities.subtracting(.append)
    }

    /// Deletes the file or the empty folder at `url`.
    public func remove(_ url: URL) throws {
        try remove(url, cancellation: Optional<CancellationFlag>.none)
    }

    /// Deletes the file or the empty folder at `url`; `cancellation` ends the waits.
    public func remove(_ url: URL, cancellation: CancellationFlag) throws {
        try remove(url, cancellation: Optional(cancellation))
    }

    /// Deletes what is at `url`, as a file or a folder when the cached listing tells which.
    private func remove(_ url: URL, cancellation: CancellationFlag?) throws {
        let target = try resolve(url, cancellation: cancellation)
        let (session, key, path) = (target.session, target.key, target.path)
        guard let parent = RemotePath.parent(of: path) else {
            throw FileSystemError.notSupported("Deleting the root of a server")
        }
        let (parentURL, name) = (key.url(path: parent), RemotePath.name(of: path))
        var kind = RemovedKind.unknown
        if case .entry(let known) = cache.lookUp(name, in: parentURL, lookingForAlike: false) {
            // A link is removed like a file, whatever it points to.
            kind = known.isDirectory && !known.isSymlink ? .directory : .file
        }
        do {
            try session.remove(path, kind: kind, cancellation: cancellation)
        } catch {
            cache.forget(parentURL)
            cache.forgetTree(key.url(path: path))
            throw error
        }
        cache.remove(name, from: parentURL)
        cache.forgetTree(key.url(path: path))
    }

    /// Renames.
    ///
    /// With `replacing` an existing file at the destination is replaced, and at no moment is it
    /// gone without the new file being in its place or the old one being kept under another name.
    ///
    /// First the plain rename is tried, which replaces in one step on a secure shell server
    /// (`posix-rename`) and on most FTP servers. When the server refuses, nothing is removed
    /// to make room: a refusal has many reasons (no permission, no such source), and removing
    /// the destination for any of them would lose it. Only when the server confirms that the
    /// source exists and that a file is in the way, that file is renamed aside, the source
    /// is renamed into its place, and the one set aside is removed last. If the second
    /// rename fails, the file set aside is renamed back; if even that fails, the error names
    /// where it was kept.
    public func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try move(source, to: destination, replacing: replacing, cancellation: Optional<CancellationFlag>.none)
    }

    /// Renames as `move(_:to:replacing:)` does; `cancellation` ends the waits until a file in the way stands aside.
    public func move(_ source: URL, to destination: URL, replacing: Bool, cancellation: CancellationFlag) throws {
        try move(source, to: destination, replacing: replacing, cancellation: Optional(cancellation))
    }

    /// Renames on the server, and makes the cached listings follow.
    private func move(_ source: URL, to destination: URL, replacing: Bool, cancellation: CancellationFlag?) throws {
        let origin = try resolve(source, cancellation: cancellation)
        guard let targetKey = ServerKey(destination), targetKey == origin.key else {
            throw FileSystemError.crossesVolumes
        }
        let target = RemotePath.of(destination)
        if origin.path == target {
            return
        }
        if !replacing, try entry(at: destination, cancellation: cancellation, beforeOverwriting: true) != nil {
            throw FileSystemError.alreadyExists(displayPath(destination))
        }
        // Whether the rename went through as one step, so the cached listings can follow it.
        var isPlain = true
        do {
            do {
                try origin.session.rename(origin.path, to: target, replacing: replacing, cancellation: cancellation)
            } catch let refusal where replacing && Self.isRefusal(refusal) {
                isPlain = false
                cache.forget(parentURL(source), parentURL(destination))
                // Asked of the server, not of what is remembered: both answers decide over a file.
                guard try origin.session.entry(at: origin.path, cancellation: cancellation) != nil,
                    let existing = try origin.session.entry(at: target, cancellation: cancellation),
                    !existing.isDirectory,
                    let directory = RemotePath.parent(of: target)
                else { throw refusal }
                try replace(target, in: directory, with: origin, refusal: refusal, cancellation: cancellation)
            }
        } catch {
            cache.forget(parentURL(source), parentURL(destination))
            cache.forgetTree(source)
            cache.forgetTree(destination)
            throw error
        }
        if isPlain {
            cache.move(
                RemotePath.name(of: origin.path),
                from: parentURL(source),
                to: parentURL(destination),
                as: RemotePath.name(of: target)
            )
        } else {
            cache.forget(parentURL(source), parentURL(destination))
        }
        // What lay below a folder that moved, or that was replaced, is somewhere else now.
        cache.forgetTree(source)
        cache.forgetTree(destination)
    }

    /// Puts the file `origin` names in the place of the file at `target` (in `directory`) on a server whose
    /// rename does not replace.
    ///
    /// The file in the way is never deleted before the new one stands in its place.
    ///
    /// The caller's flag ends only the first step. Once the file in the way stands aside, the
    /// rest is seen through whatever the flag says (it still ends with the session and at the
    /// time limits): a Cancel between the two renames would leave the name without a file.
    private func replace(
        _ target: String,
        in directory: String,
        with origin: Resolved,
        refusal: any Error,
        cancellation: CancellationFlag?
    ) throws {
        let session = origin.session
        let aside = RemotePath.join(directory, Self.asideName(for: RemotePath.name(of: target)))
        do {
            try session.rename(target, to: aside, replacing: false, cancellation: cancellation)
        } catch {
            if cancellation?.isCancelled == true { throw NetworkError.cancelled }
            // The file in the way cannot be moved either; everything is as it was.
            throw refusal
        }
        do {
            try session.rename(origin.path, to: target, replacing: false)
        } catch {
            do {
                try session.rename(aside, to: target, replacing: false)
            } catch {
                throw NetworkError.incomplete(
                    "\(RemotePath.name(of: target)) could not be replaced (\(refusal.localizedDescription)), "
                        + "and the file that was there could not be put back: it is kept on the server as \(aside)."
                )
            }
            throw error
        }
        do {
            try session.remove(aside, kind: .file)
        } catch {
            // The new file is in place; only the old one is still there under its other name.
            center.environment.log(
                "The replaced file could not be removed and stays on the server as \(aside): "
                    + error.localizedDescription
            )
        }
    }

    /// A server does not copy; the caller reads the file and writes it again.
    public func copy(_: URL, to _: URL, progress _: (Int64) -> Bool) throws {
        throw FileSystemError.crossesVolumes
    }

    /// Sets the dates or permissions `attributes` gives on the server.
    public func setAttributes(_ attributes: FileAttributes, of url: URL) throws {
        try setAttributes(attributes, of: url, cancellation: Optional<CancellationFlag>.none)
    }

    /// Sets the dates or permissions `attributes` gives on the server; `cancellation` ends the waits.
    public func setAttributes(_ attributes: FileAttributes, of url: URL, cancellation: CancellationFlag) throws {
        try setAttributes(attributes, of: url, cancellation: Optional(cancellation))
    }

    /// Sets the attributes, and enters them into the cached listing.
    private func setAttributes(_ attributes: FileAttributes, of url: URL, cancellation: CancellationFlag?) throws {
        let target = try resolve(url, cancellation: cancellation)
        let directory = parentURL(url)
        do {
            try target.session.setAttributes(attributes, of: target.path, cancellation: cancellation)
        } catch {
            cache.forget(directory)
            throw error
        }
        cache.update(RemotePath.name(of: target.path), in: directory) { entry in
            if let modified = attributes.modified { entry.modified = modified }
            if let permissions = attributes.permissions { entry.permissions = permissions & 0o7777 }
        }
    }
}
