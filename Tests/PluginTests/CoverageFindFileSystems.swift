import AFMKernel
import Foundation
import TestSupport

/// A file system over memory whose files are read as if the user cancelled while the first
/// block came in: the reader sets the flag, then hands the block over.
final class CancellingFileSystem: FileSystemProvider, @unchecked Sendable {
    /// Sets its flag at the first read and delivers each block once.
    private final class Reader: FileReader, @unchecked Sendable {
        private let cancellation: CancellationFlag
        private var data: Data?

        init(_ data: Data, cancellation: CancellationFlag) {
            self.data = data
            self.cancellation = cancellation
        }

        func read(upToCount _: Int) -> Data? {
            cancellation.cancel()
            defer { data = nil }
            return data
        }

        func seek(to _: UInt64) {
            // Read from the start only.
        }

        func close() {
            // Nothing to close.
        }
    }

    let base = MemoryFileSystem(scheme: "cancelling")
    private let cancellation: CancellationFlag

    var scheme: String { base.scheme }
    var capabilities: FileSystemCapabilities { base.capabilities }
    let readsRootedPaths = true

    init(cancellation: CancellationFlag) {
        self.cancellation = cancellation
    }

    func capabilities(for url: URL) -> FileSystemCapabilities { base.capabilities(for: url) }
    func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try base.list(directory, showHidden: showHidden)
    }
    func item(at url: URL) -> FileItem? { base.item(at: url) }
    func parent(of directory: URL) -> URL? { base.parent(of: directory) }

    func read(_ url: URL) throws -> any FileReader {
        Reader(Data((base.contents(url.path) ?? "").utf8), cancellation: cancellation)
    }

    func write(_ url: URL) throws -> any FileWriter { try base.write(url) }
    func remove(_ url: URL) throws { try base.remove(url) }

    func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try base.move(source, to: destination, replacing: replacing)
    }

    func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try base.copy(source, to: destination, progress: progress)
    }

    func setAttributes(_ attributes: FileAttributes, of url: URL) throws { try base.setAttributes(attributes, of: url) }
    func displayPath(_ url: URL) -> String { base.displayPath(url) }
    func location(from text: String) -> URL? { base.location(from: text) }
    func volume(of url: URL) -> VolumeInfo? { base.volume(of: url) }
    func createDirectory(at url: URL) throws { base.createDirectory(at: url) }

    deinit {
        // Nothing to release.
    }
}
