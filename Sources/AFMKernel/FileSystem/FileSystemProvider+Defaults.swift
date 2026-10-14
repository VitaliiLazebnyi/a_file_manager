public import Foundation

/// What a provider does not have to offer.
extension FileSystemProvider {
    public func list(_ directory: URL, showHidden: Bool, receive: ([FileItem]) -> Bool) throws {
        _ = receive(try list(directory, showHidden: showHidden))
    }

    public func capabilities(for _: URL) -> FileSystemCapabilities { capabilities }

    public func list(_ directory: URL, showHidden: Bool, cancellation _: CancellationFlag) throws -> [FileItem] {
        try list(directory, showHidden: showHidden)
    }

    public func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag, receive: ([FileItem]) -> Bool)
        throws
    {
        try list(directory, showHidden: showHidden) { items in
            !cancellation.isCancelled && receive(items) && !cancellation.isCancelled
        }
    }

    public func item(at url: URL, cancellation: CancellationFlag) -> FileItem? {
        cancellation.isCancelled ? nil : item(at: url)
    }

    public func read(_ url: URL, cancellation: CancellationFlag) throws -> any FileReader {
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        return try read(url)
    }

    public func write(_ url: URL, cancellation: CancellationFlag) throws -> any FileWriter {
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        return try write(url)
    }

    public func append(to _: URL, at _: Int64?, cancellation _: CancellationFlag) throws -> any FileWriter {
        throw FileSystemError.notSupported("Continuing a file")
    }

    public func copyMetadata(from _: URL, to _: URL) throws {
        throw FileSystemError.notSupported("Copying metadata")
    }
    public func commit(_: URL, cancellation _: CancellationFlag) {}
    public func commit(_ url: URL, cancellation: CancellationFlag, progress: (Int64, Int64) -> Bool) throws {
        if cancellation.isCancelled || !progress(0, 0) { throw CocoaError(.userCancelled) }
        try commit(url, cancellation: cancellation)
    }
    public func quarantine(of _: URL) -> Data? { nil }
    public func setQuarantine(_: Data, of _: URL) {}

    public func trash(_: URL) throws { throw FileSystemError.notSupported("Moving to the Trash") }
    public func setAttributes(_: FileAttributes, of _: URL) throws {
        throw FileSystemError.notSupported("Changing attributes")
    }
    public func displayPath(_ url: URL) -> String { url.absoluteString }
    public func location(from text: String) -> URL? {
        guard text.lowercased().hasPrefix(scheme + ":"), let url = URL(string: text), url.scheme == scheme else {
            return nil
        }
        return url
    }
    public var readsRootedPaths: Bool { scheme == "file" }
    public func places() -> [Place] { [] }
    public func volume(of _: URL) -> VolumeInfo? { nil }
    public func volume(of url: URL, cancellation: CancellationFlag) -> VolumeInfo? {
        cancellation.isCancelled ? nil : volume(of: url)
    }
    public func watch(_: [URL], onChange _: @escaping @MainActor @Sendable ([URL]) -> Void) -> (any WatchToken)? { nil }

    public func createDirectory(at url: URL, cancellation: CancellationFlag) throws {
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        try createDirectory(at: url)
    }

    public func remove(_ url: URL, cancellation: CancellationFlag) throws {
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        try remove(url)
    }

    public func move(_ source: URL, to destination: URL, replacing: Bool, cancellation: CancellationFlag) throws {
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        try move(source, to: destination, replacing: replacing)
    }

    public func setAttributes(_ attributes: FileAttributes, of url: URL, cancellation: CancellationFlag) throws {
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        try setAttributes(attributes, of: url)
    }

    public func copyMetadata(from source: URL, to destination: URL, cancellation: CancellationFlag) throws {
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        try copyMetadata(from: source, to: destination)
    }

    public func setQuarantine(_ value: Data, of url: URL, cancellation: CancellationFlag) throws {
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        try setQuarantine(value, of: url)
    }

    public func createDirectory(at url: URL, exclusive: Bool) throws {
        if exclusive, item(at: url) != nil { throw FileSystemError.alreadyExists(displayPath(url)) }
        try createDirectory(at: url)
    }

    public func remove(_ url: URL, below _: URL, cancellation: CancellationFlag) throws {
        try remove(url, cancellation: cancellation)
    }

    public func createDirectory(at url: URL, exclusive: Bool, cancellation: CancellationFlag) throws {
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        guard exclusive else {
            try createDirectory(at: url, cancellation: cancellation)
            return
        }
        try createDirectory(at: url, exclusive: true)
    }

    public func realLocation(of _: URL) -> URL? { nil }
    public var connectsToServer: Bool { false }
    public func readOrder(of urls: [URL]) -> [URL] { urls }

    public func copy(_ source: URL, to destination: URL, cancellation: CancellationFlag, progress: (Int64) -> Bool)
        throws
    {
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        do {
            try copy(source, to: destination) { progress($0) && !cancellation.isCancelled }
        } catch {
            // However the copy ended, a caller that set the flag is told that it was stopped.
            throw cancellation.isCancelled ? CocoaError(.userCancelled) : error
        }
    }
}
