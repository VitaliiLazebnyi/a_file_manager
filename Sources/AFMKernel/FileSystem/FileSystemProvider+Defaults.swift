public import Foundation

/// What a provider does not have to offer.
extension FileSystemProvider {
    /// True for local disks (`file`) only: other file systems write their locations with
    /// their scheme, and a path from the root is one of the local disks.
    public var readsRootedPaths: Bool { scheme == "file" }

    /// False: a file system is on this Mac unless it says otherwise.
    public var connectsToServer: Bool { false }

    /// Throws the error of a call the user stopped once `cancellation` is set.
    private static func unlessCancelled(_ cancellation: CancellationFlag) throws {
        if cancellation.isCancelled {
            throw CocoaError(.userCancelled)
        }
    }

    /// `capabilities`: the same everywhere.
    public func capabilities(for _: URL) -> FileSystemCapabilities { capabilities }

    /// Delivers the whole listing as one batch.
    public func list(_ directory: URL, showHidden: Bool, receive: ([FileItem]) -> Bool) throws {
        _ = receive(try list(directory, showHidden: showHidden))
    }

    /// `list(_:showHidden:)`, which cannot be ended early.
    public func list(_ directory: URL, showHidden: Bool, cancellation _: CancellationFlag) throws -> [FileItem] {
        try list(directory, showHidden: showHidden)
    }

    /// `list(_:showHidden:receive:)`; no batch is handed on once `cancellation` is set, and
    /// none is asked for after it.
    public func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag, receive: ([FileItem]) -> Bool)
        throws
    {
        try list(directory, showHidden: showHidden) { items in
            !cancellation.isCancelled && receive(items) && !cancellation.isCancelled
        }
    }

    /// `item(at:)`, or nil without asking once `cancellation` is set.
    public func item(at url: URL, cancellation: CancellationFlag) -> FileItem? {
        cancellation.isCancelled ? nil : item(at: url)
    }

    /// `read(_:)`, or a throw without opening once `cancellation` is set.
    public func read(_ url: URL, cancellation: CancellationFlag) throws -> any FileReader {
        try Self.unlessCancelled(cancellation)
        return try read(url)
    }

    /// `write(_:)`, or a throw without opening once `cancellation` is set.
    public func write(_ url: URL, cancellation: CancellationFlag) throws -> any FileWriter {
        try Self.unlessCancelled(cancellation)
        return try write(url)
    }

    /// Throws `FileSystemError.notSupported`: files cannot be continued.
    public func append(to _: URL, at _: Int64?, cancellation _: CancellationFlag) throws -> any FileWriter {
        throw FileSystemError.notSupported("Continuing a file")
    }

    /// Throws `FileSystemError.notSupported`: no metadata is kept.
    public func copyMetadata(from _: URL, to _: URL) throws {
        throw FileSystemError.notSupported("Copying metadata")
    }

    /// Does nothing: what is written is where it belongs at once.
    public func commit(_: URL, cancellation _: CancellationFlag) {
        // Nothing is kept back.
    }

    /// Asks `progress` once, then `commit(_:cancellation:)`; throws without committing when
    /// `cancellation` is set or `progress` says stop.
    public func commit(_ url: URL, cancellation: CancellationFlag, progress: (Int64, Int64) -> Bool) throws {
        guard !cancellation.isCancelled, progress(0, 0) else {
            throw CocoaError(.userCancelled)
        }
        try commit(url, cancellation: cancellation)
    }

    /// Nil: no file here carries a mark of having come from elsewhere.
    public func quarantine(of _: URL) -> Data? { nil }

    /// Does nothing: marks cannot be kept here.
    public func setQuarantine(_: Data, of _: URL) {
        // No marks are kept.
    }

    /// Throws `FileSystemError.notSupported`: there is no Trash.
    public func trash(_: URL) throws {
        throw FileSystemError.notSupported("Moving to the Trash")
    }

    /// Throws `FileSystemError.notSupported`: attributes cannot be changed.
    public func setAttributes(_: FileAttributes, of _: URL) throws {
        throw FileSystemError.notSupported("Changing attributes")
    }

    /// The URL as text, scheme and all.
    public func displayPath(_ url: URL) -> String { url.absoluteString }

    /// A URL of this file system's scheme written out in full; nil for any other text.
    public func location(from text: String) -> URL? {
        guard text.lowercased().hasPrefix(scheme + ":"), let url = URL(string: text), url.scheme == scheme else {
            return nil
        }
        return url
    }

    /// None: the file system adds nothing to the volume list.
    public func places() -> [Place] { [] }

    /// Nil: nothing is known of the volume.
    public func volume(of _: URL) -> VolumeInfo? { nil }

    /// `volume(of:)`, or nil without asking once `cancellation` is set.
    public func volume(of url: URL, cancellation: CancellationFlag) -> VolumeInfo? {
        cancellation.isCancelled ? nil : volume(of: url)
    }

    /// Nil: changes cannot be watched, and `onChange` is never called.
    @preconcurrency
    public func watch(_: [URL], onChange: @escaping @MainActor @Sendable ([URL]) -> Void) -> (any WatchToken)? {
        withExtendedLifetime(onChange) {
            // Let go of here: nothing will report to it.
        }
        return nil
    }

    /// `createDirectory(at:)`, or a throw without it once `cancellation` is set.
    public func createDirectory(at url: URL, cancellation: CancellationFlag) throws {
        try Self.unlessCancelled(cancellation)
        try createDirectory(at: url)
    }

    /// `remove(_:)`, or a throw without it once `cancellation` is set.
    public func remove(_ url: URL, cancellation: CancellationFlag) throws {
        try Self.unlessCancelled(cancellation)
        try remove(url)
    }

    /// `move(_:to:replacing:)`, or a throw without it once `cancellation` is set.
    public func move(_ source: URL, to destination: URL, replacing: Bool, cancellation: CancellationFlag) throws {
        try Self.unlessCancelled(cancellation)
        try move(source, to: destination, replacing: replacing)
    }

    /// `setAttributes(_:of:)`, or a throw without it once `cancellation` is set.
    public func setAttributes(_ attributes: FileAttributes, of url: URL, cancellation: CancellationFlag) throws {
        try Self.unlessCancelled(cancellation)
        try setAttributes(attributes, of: url)
    }

    /// `copyMetadata(from:to:)`, or a throw without it once `cancellation` is set.
    public func copyMetadata(from source: URL, to destination: URL, cancellation: CancellationFlag) throws {
        try Self.unlessCancelled(cancellation)
        try copyMetadata(from: source, to: destination)
    }

    /// `setQuarantine(_:of:)`, or a throw without it once `cancellation` is set.
    public func setQuarantine(_ value: Data, of url: URL, cancellation: CancellationFlag) throws {
        try Self.unlessCancelled(cancellation)
        try setQuarantine(value, of: url)
    }

    /// `createDirectory(at:)`, after a look with `item(at:)` when `exclusive` is set.
    public func createDirectory(at url: URL, exclusive: Bool) throws {
        if exclusive, item(at: url) != nil {
            throw FileSystemError.alreadyExists(displayPath(url))
        }
        try createDirectory(at: url)
    }

    /// `remove(_:cancellation:)`, without a look at the way.
    public func remove(_ url: URL, below _: URL, cancellation: CancellationFlag) throws {
        try remove(url, cancellation: cancellation)
    }

    /// `createDirectory(at:exclusive:)`, or a throw without it once `cancellation` is set.
    public func createDirectory(at url: URL, exclusive: Bool, cancellation: CancellationFlag) throws {
        try Self.unlessCancelled(cancellation)
        guard exclusive else {
            try createDirectory(at: url, cancellation: cancellation)
            return
        }
        try createDirectory(at: url, exclusive: true)
    }

    /// Nil: every location is itself.
    public func realLocation(of _: URL) -> URL? { nil }

    /// The order the files were given in.
    public func readOrder(of urls: [URL]) -> [URL] { urls }

    /// `copy(_:to:progress:)`, which looks at the flag whenever `progress` is asked.
    public func copy(_ source: URL, to destination: URL, cancellation: CancellationFlag, progress: (Int64) -> Bool)
        throws
    {
        try Self.unlessCancelled(cancellation)
        do {
            try copy(source, to: destination) { progress($0) && !cancellation.isCancelled }
        } catch {
            // However the copy ended, a caller that set the flag is told that it was stopped.
            throw cancellation.isCancelled ? CocoaError(.userCancelled) : error
        }
    }
}
