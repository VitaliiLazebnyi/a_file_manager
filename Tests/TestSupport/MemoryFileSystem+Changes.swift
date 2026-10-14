public import AFMKernel
public import Foundation

/// Changing the tree: folders, removing, moving, copying, commits, metadata and marks; the
/// calls with a cancellation flag are recorded and can stall (`stallsChanges`).
extension MemoryFileSystem {
    /// Makes the folder at `url` and every folder above it that is missing.
    public func createDirectory(at url: URL) {
        synchronized {
            var path = key(url)
            while path != "/" {
                if nodes[path] == nil {
                    nodes[path] = .directory
                }
                path = parentKey(path)
            }
        }
    }

    /// Records that the metadata of `source` was copied to `destination` when `keepsMetadata`;
    /// otherwise throws that it is not supported.
    public func copyMetadata(from source: URL, to destination: URL) throws {
        guard options.value.keepsMetadata else {
            throw FileSystemError.notSupported("Copying metadata")
        }
        try synchronized {
            guard nodes[key(destination)] != nil else {
                throw NotFound(path: decoded(key(destination)))
            }
            records.metadataCopied.append((source, decoded(key(destination))))
        }
    }

    /// Records the commit of `url`; throws `commitFailure` when one is set.
    public func commit(_ url: URL, cancellation _: CancellationFlag) throws {
        synchronized { records.committed.append(decoded(key(url))) }
        if let failure = options.value.commitFailure {
            throw failure
        }
    }

    /// Asks `progress` `commitSteps` times (at least once) before it commits; throws
    /// `userCancelled` without committing when `progress` says no or the flag is set.
    public func commit(_ url: URL, cancellation: CancellationFlag, progress: (Int64, Int64) -> Bool) throws {
        let steps = options.value.commitSteps
        for step in 0..<max(steps, 1) where cancellation.isCancelled || !progress(Int64(step), Int64(steps)) {
            throw CocoaError(.userCancelled)
        }
        try commit(url, cancellation: cancellation)
    }

    /// The mark set as `quarantineValue`, the same for every file.
    public func quarantine(of _: URL) -> Data? { options.value.quarantineValue }

    /// Records `value` as the mark of the entry at `url` (`quarantineMarks`).
    public func setQuarantine(_ value: Data, of url: URL) throws {
        try synchronized {
            guard nodes[key(url)] != nil else {
                throw NotFound(path: decoded(key(url)))
            }
            records.quarantined[decoded(key(url))] = value
        }
    }

    /// Removes the file or empty folder at `url`; a folder that holds anything is refused.
    public func remove(_ url: URL) throws {
        let path = key(url)
        try synchronized {
            guard nodes[path] != nil else {
                throw NotFound(path: decoded(path))
            }
            guard !nodes.keys.contains(where: { $0.hasPrefix(path + "/") }) else {
                throw FileSystemError.notSupported("Removing the non-empty \(decoded(path))")
            }
            nodes[path] = nil
        }
    }

    /// Moves the entry at `source`, with everything below it, to `destination`; what is there
    /// is replaced only with `replacing`.
    public func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        let (from, target) = (key(source), key(destination))
        try synchronized {
            guard nodes[from] != nil else {
                throw NotFound(path: decoded(from))
            }
            if nodes[target] != nil, !replacing {
                throw FileSystemError.alreadyExists(decoded(target))
            }
            for candidate in nodes.keys.sorted() where candidate == from || candidate.hasPrefix(from + "/") {
                nodes[target + candidate.dropFirst(from.count)] = nodes[candidate]
                nodes[candidate] = nil
            }
        }
    }

    /// Copies the file at `source` to the new `destination`, reporting the bytes copied after
    /// every block of `copyBlockSize`; throws `userCancelled` when `progress` says no, and
    /// `crossesVolumes` with `refusesInternalCopy`.
    public func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        let current = options.value
        if current.refusesInternalCopy {
            throw FileSystemError.crossesVolumes
        }
        let contents = try synchronized {
            guard case .file(let contents)? = nodes[key(source)] else {
                throw NotFound(path: decoded(key(source)))
            }
            guard nodes[key(destination)] == nil else {
                throw FileSystemError.alreadyExists(decoded(key(destination)))
            }
            return contents
        }
        var copied = 0
        while copied < contents.data.count {
            copied = min(contents.data.count, copied + current.copyBlockSize)
            if !progress(Int64(copied)) {
                throw CocoaError(.userCancelled)
            }
        }
        synchronized { nodes[key(destination)] = .file(contents) }
    }

    /// `createDirectory(at:)`, recorded, held while `stallsChanges`.
    public func createDirectory(at url: URL, cancellation: CancellationFlag) throws {
        try flaggedChange("createDirectory", url, cancellation)
        createDirectory(at: url)
    }

    /// `remove(_:)`, recorded, held while `stallsChanges`.
    public func remove(_ url: URL, cancellation: CancellationFlag) throws {
        try flaggedChange("remove", url, cancellation)
        try remove(url)
    }

    /// `remove(_:)`, recorded with the root, held while `stallsChanges`: a file system without
    /// links has nothing to check below the root.
    public func remove(_ url: URL, below root: URL, cancellation: CancellationFlag) throws {
        try flaggedChange("remove below " + decoded(key(root)), url, cancellation)
        try remove(url)
    }

    /// `move(_:to:replacing:)`, recorded, held while `stallsChanges`.
    public func move(_ source: URL, to destination: URL, replacing: Bool, cancellation: CancellationFlag) throws {
        try flaggedChange("move", source, cancellation)
        try move(source, to: destination, replacing: replacing)
    }

    /// The protocol's `setAttributes`, recorded, held while `stallsChanges`.
    public func setAttributes(_ attributes: FileAttributes, of url: URL, cancellation: CancellationFlag) throws {
        try flaggedChange("setAttributes", url, cancellation)
        try setAttributes(attributes, of: url)
    }

    /// `copyMetadata(from:to:)`, recorded, held while `stallsChanges`.
    public func copyMetadata(from source: URL, to destination: URL, cancellation: CancellationFlag) throws {
        try flaggedChange("copyMetadata", destination, cancellation)
        try copyMetadata(from: source, to: destination)
    }

    /// `setQuarantine(_:of:)`, recorded, held while `stallsChanges`.
    public func setQuarantine(_ value: Data, of url: URL, cancellation: CancellationFlag) throws {
        try flaggedChange("setQuarantine", url, cancellation)
        try setQuarantine(value, of: url)
    }

    /// `copy(_:to:progress:)`, recorded, held while `stallsChanges`, and stopped at the next
    /// block once the flag is set.
    public func copy(
        _ source: URL,
        to destination: URL,
        cancellation: CancellationFlag,
        progress: (Int64) -> Bool
    ) throws {
        try flaggedChange("copy", destination, cancellation)
        try copy(source, to: destination) { progress($0) && !cancellation.isCancelled }
    }

    /// Notes a changing call that came with a flag, and holds it while `stallsChanges` until
    /// released; throws `userCancelled` when the flag is (or gets) set.
    private func flaggedChange(_ what: String, _ url: URL, _ cancellation: CancellationFlag) throws {
        synchronized { records.flagged.append(what + " " + decoded(key(url))) }
        if cancellation.isCancelled {
            throw CocoaError(.userCancelled)
        }
        guard options.value.stallsChanges else {
            return
        }
        let waking = stalls.waking(on: cancellation)
        defer { _ = waking }
        stalls.holdChange(cancellation: cancellation)
        if cancellation.isCancelled {
            throw CocoaError(.userCancelled)
        }
    }
}
