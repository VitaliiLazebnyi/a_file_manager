public import AFMKernel
public import Foundation

/// A file system that exists only in memory (`mem:` URLs).
///
/// It stands in for the kinds of location the program does not have yet (archives, servers)
/// and shows that panels, jobs and search need nothing but the provider interface. It can be
/// made slow, read-only or awkward in the ways a real remote file system is (`Options`).
///
/// Unchecked: the tree and the records are guarded by `lock`, the options by their own lock
/// (`options`), and what waits by `stalls`.
public final class MemoryFileSystem: FileSystemProvider, @unchecked Sendable {
    /// An entry of the tree.
    internal enum Node {
        /// A folder; what it holds are the nodes whose paths start with its own.
        case directory
        /// A file.
        case file(Contents)
    }

    /// What a file holds.
    internal struct Contents {
        /// Its bytes.
        internal var data: Data
        /// When it was last changed.
        internal var modified: Date
        /// Its permission bits.
        internal var permissions: UInt16
    }

    /// What the file system was asked and did, for tests to look at (`MemoryFileSystem+Records`).
    internal struct Records {
        /// The directories listed piece by piece, in order.
        internal var listed: [String] = []
        /// How many listings piece by piece are under way now.
        internal var listing = 0
        /// The most listings piece by piece that were ever under way at once.
        internal var mostListing = 0
        /// The locations `commit` was called for, in order.
        internal var committed: [String] = []
        /// Path → the mark `setQuarantine` put there.
        internal var quarantined: [String: Data] = [:]
        /// Every `copyMetadata` carried out.
        internal var metadataCopied: [(from: URL, to: String)] = []
        /// How many readers and writers were interrupted.
        internal var interrupted = 0
        /// The changing calls that came with a cancellation flag, as `"remove /a/b"`.
        internal var flagged: [String] = []
    }

    /// The URL scheme this file system answers to (`mem` unless another is given).
    public let scheme: String
    /// Always true: paths read from the root of the URL, whatever its host.
    public let readsRootedPaths = true
    /// The tree, by path, with every byte that is not ASCII written as `%XX`: two names that differ only in how an
    /// accent is written (`é` in one character or in two) are equal as `String`s, and here they are two files, as on a
    /// server or a disk from elsewhere.
    ///
    /// Guarded by `lock`.
    internal var nodes: [String: Node] = ["/": .directory]
    /// Guarded by `lock`.
    internal var records = Records()
    /// Guards `nodes` and `records`.
    internal let lock = NSLock()
    /// The settings (`MemoryFileSystem+Options`).
    ///
    /// A lock of their own: a test changes them while other threads are inside the file system, and they are read with
    /// `lock` held as well.
    internal let options = Shared(Options())
    /// Where calls wait while the file system stalls, and who waits there.
    internal let stalls = MemoryStalls()

    /// An empty file system (nothing but its root) for URLs of `scheme`.
    public init(scheme: String = "mem") {
        self.scheme = scheme
    }

    /// What `capabilities(for:)` answers: the location's own capabilities when `capabilitiesAt`
    /// is set, otherwise `capabilities`.
    public func capabilities(for url: URL) -> FileSystemCapabilities {
        let current = options.value
        return current.capabilitiesAt?(url) ?? current.capabilities
    }

    /// The entry at `url`, or nil when there is none.
    public func item(at url: URL) -> FileItem? {
        synchronized { nodes[key(url)].map { makeItem(key(url), $0) } }
    }

    /// The folder above `directory`; nil for the root.
    public func parent(of directory: URL) -> URL? {
        let own = key(directory)
        return own == "/" ? nil : url(decoded(parentKey(own)))
    }

    /// Runs `body` with `lock` held.
    internal func synchronized<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// The key of `url` in `nodes`: its standardized path without a trailing slash, with every
    /// byte that is not ASCII, and `%` itself, written as `%XX`.
    internal func key(_ url: URL) -> String {
        let path = url.standardized.path
        if path.isEmpty {
            return "/"
        }
        let trimmed = path.utf8.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        guard trimmed.utf8.contains(where: { $0 >= 0x80 || $0 == 0x25 }) else {
            return trimmed
        }
        return trimmed.utf8.reduce(into: "") { encoded, byte in
            if byte >= 0x80 || byte == 0x25 {
                encoded += String(format: "%%%02X", byte)
            } else {
                encoded.unicodeScalars.append(Unicode.Scalar(byte))
            }
        }
    }

    /// The path a key stands for, as it was written.
    internal func decoded(_ key: String) -> String {
        guard key.utf8.contains(0x25) else {
            return key
        }
        var bytes: [UInt8] = []
        var rest = key.utf8[...]
        while let byte = rest.first {
            if byte == 0x25, let value = UInt8(String(Substring(rest.dropFirst().prefix(2))), radix: 16) {
                bytes.append(value)
                rest = rest.dropFirst(3)
            } else {
                bytes.append(byte)
                rest = rest.dropFirst()
            }
        }
        // The bytes of a key are those of a path, which is UTF-8.
        return String(bytes: bytes, encoding: .utf8) ?? key
    }

    /// The key of the folder above the one of `key`.
    internal func parentKey(_ key: String) -> String {
        guard let slash = key.lastIndex(of: "/"), slash != key.startIndex else {
            return "/"
        }
        return String(key[..<slash])
    }

    /// The entry for the node at `key`.
    internal func makeItem(_ key: String, _ node: Node) -> FileItem {
        let path = decoded(key)
        // Cut by hand: the system's own way of taking the last part may rewrite the accents.
        let name = path == "/" ? path : String(path[path.index(after: path.lastIndex(of: "/") ?? path.startIndex)...])
        switch node {
        case .directory:
            return FileItem(
                url: url(path),
                name: name,
                isDirectory: true,
                isHidden: name.hasPrefix("."),
                permissions: 0o755
            )

        case .file(let contents):
            return FileItem(
                url: url(path),
                name: name,
                isDirectory: false,
                isHidden: name.hasPrefix("."),
                size: Int64(contents.data.count),
                modified: contents.modified,
                permissions: contents.permissions
            )
        }
    }

    deinit {
        // Nothing to release.
    }
}
