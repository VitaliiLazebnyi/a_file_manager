public import AFMKernel
public import Foundation

/// Listing directories: at once, piece by piece, and the way a slow or stalled server answers.
extension MemoryFileSystem {
    /// The entries of `directory`, by name (names that read the same by their bytes); hidden ones only with
    /// `showHidden`.
    ///
    /// Throws `Unreadable` for the paths in `unreadable` and `NotFound` where there is no folder.
    public func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        let unreadable = options.value.unreadable
        return try synchronized {
            let parent = key(directory)
            if unreadable.contains(decoded(parent)) {
                throw Unreadable(path: decoded(parent))
            }
            guard case .directory? = nodes[parent] else {
                throw NotFound(path: parent)
            }
            return
                nodes
                .filter { $0.key != "/" && parentKey($0.key) == parent }
                .map { makeItem($0.key, $0.value) }
                .filter { showHidden || !$0.isHidden }
                // Names that read the same keep one order: by their bytes.
                .sorted { first, second in
                    first.name != second.name
                        ? first.name < second.name : first.name.utf8.lexicographicallyPrecedes(second.name.utf8)
                }
        }
    }

    /// The entries of `directory` piece by piece (in batches of `listBatchSize`, with
    /// `listStartDelay` and `listBatchDelay` slept through), until `receive` wants no more.
    public func list(_ directory: URL, showHidden: Bool, receive: ([FileItem]) -> Bool) throws {
        try list(directory, showHidden: showHidden, cancellation: nil, receive: receive)
    }

    /// The same, ended quietly, having delivered what it had, as soon as `cancellation` is set;
    /// it stalls with `stallsListings` until then or until `releaseStalls()`.
    public func list(
        _ directory: URL,
        showHidden: Bool,
        cancellation: CancellationFlag,
        receive: ([FileItem]) -> Bool
    ) throws {
        try list(directory, showHidden: showHidden, cancellation: Optional(cancellation), receive: receive)
    }

    /// The whole directory at once, as sizes are added up; it stalls like the other, and is not counted among the
    /// `listRequests`, like `list(_:showHidden:)`.
    ///
    /// Empty when the flag was set.
    public func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag) throws -> [FileItem] {
        let waking = stalls.waking(on: cancellation)
        defer { _ = waking }
        let path = decoded(key(directory))
        guard stalls.pause(path, stalling: stallsListing(of: path), until: Date(), cancellation: cancellation) else {
            return []
        }
        return try list(directory, showHidden: showHidden)
    }

    /// Lists piece by piece; with a flag, a listing that stalls or pauses ends as soon as the
    /// flag is set, having delivered what it had: quietly, as a file system may.
    private func list(
        _ directory: URL,
        showHidden: Bool,
        cancellation: CancellationFlag?,
        receive: ([FileItem]) -> Bool
    ) throws {
        let path = decoded(key(directory))
        synchronized {
            records.listed.append(path)
            records.listing += 1
            records.mostListing = max(records.mostListing, records.listing)
        }
        defer { synchronized { records.listing -= 1 } }
        let waking = cancellation.map(stalls.waking(on:))
        defer { _ = waking }
        let current = options.value
        guard pause(path, for: current.listStartDelay, cancellation: cancellation),
            pause(path, for: 0, cancellation: cancellation, stalling: stallsListing(of: path))
        else {
            return
        }
        let items = try list(directory, showHidden: showHidden)
        guard let size = current.listBatchSize, size > 0 else {
            _ = receive(items)
            return
        }
        for start in stride(from: 0, to: items.count, by: size) {
            guard pause(path, for: current.listBatchDelay, cancellation: cancellation) else {
                return
            }
            if !receive(Array(items[start..<min(start + size, items.count)])) {
                return
            }
        }
    }

    /// Waits `time` (or, `stalling`, until released) before a listing of `path` goes on; false when `cancellation` was
    /// set meanwhile.
    ///
    /// Without a flag it simply sleeps.
    private func pause(
        _ path: String,
        for time: TimeInterval,
        cancellation: CancellationFlag?,
        stalling: Bool = false
    ) -> Bool {
        guard let cancellation else {
            if time > 0 {
                Thread.sleep(forTimeInterval: time)
            }
            return true
        }
        return stalls.pause(
            path,
            stalling: stalling,
            until: Date(timeIntervalSinceNow: time),
            cancellation: cancellation
        )
    }
}
