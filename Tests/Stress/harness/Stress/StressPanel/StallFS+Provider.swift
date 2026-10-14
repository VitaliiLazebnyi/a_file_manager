import AFMKernel
import Foundation
import TestSupport

/// The provider interface: each call is counted and, while stalled, held (see `StallFS`).
extension StallFS: FileSystemProvider {
    /// What the memory file system can do.
    internal var capabilities: FileSystemCapabilities { inner.capabilities }
    /// The memory file system's own rule for rooted paths.
    internal var readsRootedPaths: Bool { inner.readsRootedPaths }

    /// By the protocol `capabilities(for:)` answers at once, from what the provider knows (validation asks
    /// it on the main thread at every tick), so a silent server does not hold it up: counted, never stalled.
    internal func capabilities(for url: URL) -> FileSystemCapabilities {
        count("capabilities(for:)")
        return inner.capabilities(for: url)
    }

    /// Held; lists the directory.
    internal func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        wait("list (no cancellation)")
        return try inner.list(directory, showHidden: showHidden)
    }

    /// Held; lists the directory piece by piece.
    internal func list(_ directory: URL, showHidden: Bool, receive: ([FileItem]) -> Bool) throws {
        wait("list receive (no cancellation)")
        try inner.list(directory, showHidden: showHidden, receive: receive)
    }

    /// Held until cancelled; lists the directory.
    internal func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag) throws -> [FileItem] {
        wait("list(cancellation:)", cancellation: cancellation)
        return try inner.list(directory, showHidden: showHidden, cancellation: cancellation)
    }

    /// Held until cancelled; lists the directory piece by piece.
    internal func list(
        _ directory: URL,
        showHidden: Bool,
        cancellation: CancellationFlag,
        receive: ([FileItem]) -> Bool
    ) throws {
        wait("list(cancellation:receive:)", cancellation: cancellation)
        try inner.list(directory, showHidden: showHidden, cancellation: cancellation, receive: receive)
    }

    /// Held until cancelled; names and kinds of the directory's entries.
    internal func entries(
        of directory: URL,
        showHidden: Bool,
        foldersOnly: Bool,
        cancellation: CancellationFlag
    ) throws -> [DirectoryEntry] {
        wait("entries(of:)", cancellation: cancellation)
        return try inner.entries(
            of: directory,
            showHidden: showHidden,
            foldersOnly: foldersOnly,
            cancellation: cancellation
        )
    }

    /// Held; the entry at `url`.
    internal func item(at url: URL) -> FileItem? {
        wait("item(at:)")
        return inner.item(at: url)
    }

    /// Held until cancelled; the entry at `url`.
    internal func item(at url: URL, cancellation: CancellationFlag) -> FileItem? {
        wait("item(at:cancellation:)", cancellation: cancellation)
        return inner.item(at: url)
    }

    /// The directory above, from the URL alone.
    internal func parent(of directory: URL) -> URL? { inner.parent(of: directory) }

    /// Held; opens the file for reading.
    internal func read(_ url: URL) throws -> any FileReader {
        wait("read")
        return try inner.read(url)
    }

    /// Held until cancelled; opens the file for reading.
    internal func read(_ url: URL, cancellation: CancellationFlag) throws -> any FileReader {
        wait("read(cancellation:)", cancellation: cancellation)
        return try inner.read(url, cancellation: cancellation)
    }

    /// Held; makes the directory.
    internal func createDirectory(at url: URL) {
        wait("createDirectory")
        inner.createDirectory(at: url)
    }

    /// Held; creates a new file.
    internal func write(_ url: URL) throws -> any FileWriter {
        wait("write")
        return try inner.write(url)
    }

    /// Held until cancelled; creates a new file.
    internal func write(_ url: URL, cancellation: CancellationFlag) throws -> any FileWriter {
        wait("write(cancellation:)", cancellation: cancellation)
        return try inner.write(url, cancellation: cancellation)
    }

    /// Held until cancelled; opens an existing file to continue it.
    internal func append(to url: URL, at offset: Int64?, cancellation: CancellationFlag) throws -> any FileWriter {
        wait("append", cancellation: cancellation)
        return try inner.append(to: url, at: offset, cancellation: cancellation)
    }

    /// Held; deletes one item.
    internal func remove(_ url: URL) throws {
        wait("remove")
        try inner.remove(url)
    }

    /// Held; moves one item to the trash.
    internal func trash(_ url: URL) throws {
        wait("trash")
        try inner.trash(url)
    }

    /// Held; moves one item.
    internal func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        wait("move")
        try inner.move(source, to: destination, replacing: replacing)
    }

    /// Held; copies one file.
    internal func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        wait("copy")
        try inner.copy(source, to: destination, progress: progress)
    }

    /// Held; changes attributes.
    internal func setAttributes(_ attributes: FileAttributes, of url: URL) throws {
        wait("setAttributes")
        try inner.setAttributes(attributes, of: url)
    }

    /// Held; carries metadata over.
    internal func copyMetadata(from source: URL, to destination: URL) throws {
        wait("copyMetadata")
        try inner.copyMetadata(from: source, to: destination)
    }

    /// Held until cancelled; makes what was written durable.
    internal func commit(_ url: URL, cancellation: CancellationFlag) throws {
        wait("commit", cancellation: cancellation)
        try inner.commit(url, cancellation: cancellation)
    }

    /// Held; the quarantine mark.
    internal func quarantine(of url: URL) -> Data? {
        wait("quarantine")
        return inner.quarantine(of: url)
    }

    /// Held; puts a quarantine mark on.
    internal func setQuarantine(_ value: Data, of url: URL) throws {
        wait("setQuarantine")
        try inner.setQuarantine(value, of: url)
    }

    /// How a location is written for the user.
    internal func displayPath(_ url: URL) -> String { inner.displayPath(url) }

    /// The location the user typed.
    internal func location(from text: String) -> URL? { inner.location(from: text) }

    /// Held; the places of the memory file system.
    internal func places() -> [Place] {
        wait("places")
        return inner.places()
    }

    /// Held; a share that is not local.
    internal func volume(of _: URL) -> VolumeInfo? {
        wait("volume(of:)")
        return VolumeInfo(name: "Stalling share", freeBytes: 1 << 30, totalBytes: 1 << 40, isLocal: false)
    }

    /// Held until cancelled; the size of everything below the directory.
    internal func totalSize(of directory: URL, cancellation: CancellationFlag) -> Int64 {
        wait("totalSize", cancellation: cancellation)
        return inner.totalSize(of: directory, cancellation: cancellation)
    }
}
