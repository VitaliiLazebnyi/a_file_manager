import AFMKernel
public import Foundation

/// What a test uses to fill the file system and to look at what it was asked and did.
extension MemoryFileSystem {
    /// The path of `path` relative to the root no longer exists.
    public struct NotFound: LocalizedError {
        /// The path, as the file system writes it.
        public let path: String

        /// Says that the path does not exist.
        public var errorDescription: String? { "\(path) does not exist." }
    }

    /// The listing of `path` failed, as for a folder without permission (`unreadable`).
    public struct Unreadable: LocalizedError {
        /// The path, as the file system writes it.
        public let path: String

        /// Says that the path cannot be read.
        public var errorDescription: String? { "\(path) cannot be read." }
    }

    /// The directories a listing was asked for piece by piece (the way panels read), in the
    /// order of the requests: for counting how often the "server" was asked.
    public var listRequests: [String] { synchronized { records.listed } }

    /// The locations `commit` was called for, in order.
    public var commits: [String] { synchronized { records.committed } }

    /// Path → the mark `setQuarantine` put there.
    public var quarantineMarks: [String: Data] { synchronized { records.quarantined } }

    /// Every `copyMetadata` that was carried out: from which location to which path.
    public var metadataCopies: [(from: URL, to: String)] { synchronized { records.metadataCopied } }

    /// How many readers and writers were interrupted.
    public var interruptions: Int { synchronized { records.interrupted } }

    /// How many changing calls are waiting in a stall at this moment (`stallsChanges`).
    public var stalledChanges: Int { stalls.waitingChanges }

    /// How many reads and writes are waiting in a stall at this moment (`stallsReads`, `stallsWrites`).
    ///
    /// A test that needs them to be under way waits for this count.
    public var stalledTransfers: Int { stalls.waitingTransfers }

    /// The changing calls that came with a cancellation flag, in order, as `"remove /a/b"`
    /// (`createDirectory`, `remove`, `move`, `setAttributes`, `copyMetadata`,
    /// `setQuarantine`, `copy`, with the path of the item changed): for checking that a
    /// caller that holds a flag passes it.
    public var flaggedChanges: [String] { synchronized { records.flagged } }

    /// The largest number of listings piece by piece that were ever under way at the same time.
    public var mostListingsAtOnce: Int { synchronized { records.mostListing } }

    /// Every path below the root, sorted; for checking that nothing was left behind.
    public var allPaths: [String] {
        synchronized { nodes.keys.filter { $0 != "/" }.map(decoded).sorted() }
    }

    /// The location of `path` (read from the root, a leading `/` added when missing).
    public func url(_ path: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = ""
        components.path = path.hasPrefix("/") ? path : "/" + path
        guard let url = components.url else {
            preconditionFailure("\(path) is not a path")
        }
        return url
    }

    /// Puts a file at `path`, with the folders above it, replacing what was there.
    ///
    /// Returns its location.
    @discardableResult
    public func addFile(
        _ path: String,
        _ content: String = "x",
        modified: Date = Date(timeIntervalSince1970: 1_000_000),
        permissions: UInt16 = 0o644
    ) -> URL {
        let url = url(path)
        createDirectory(at: url.deletingLastPathComponent())
        synchronized {
            nodes[key(url)] = .file(Contents(data: Data(content.utf8), modified: modified, permissions: permissions))
        }
        return url
    }

    /// Makes a folder at `path`, with the folders above it.
    ///
    /// Returns its location.
    @discardableResult
    public func addDirectory(_ path: String) -> URL {
        let url = url(path)
        createDirectory(at: url)
        return url
    }

    /// The text of the file at `path`; nil when there is no file or it is not UTF-8.
    public func contents(_ path: String) -> String? {
        synchronized {
            guard case .file(let contents)? = nodes[key(url(path))] else {
                return nil
            }
            return String(bytes: contents.data, encoding: .utf8)
        }
    }

    /// Whether anything is at `path`.
    public func exists(_ path: String) -> Bool {
        synchronized { nodes[key(url(path))] != nil }
    }

    /// Removes a path and everything below it, as another program would.
    public func removeTree(_ path: String) {
        let top = key(url(path))
        synchronized {
            for candidate in nodes.keys where candidate == top || candidate.hasPrefix(top + "/") {
                nodes[candidate] = nil
            }
        }
    }

    /// How many listings piece by piece asked for `path` so far.
    public func listRequests(for path: String) -> Int { listRequests.filter { $0 == path }.count }

    /// How many listings of `path` are waiting in a stall at this moment.
    ///
    /// A test that needs a listing to be under way waits for this to be 1 (a condition, not a length of time) and lets
    /// it go with `releaseStalls()` or its flag.
    public func stalledListings(of path: String) -> Int { stalls.waitingListings(of: path) }

    /// Lets everything that stalls go on, and nothing stall from now on, as when the server
    /// answers after all.
    public func releaseStalls() { stalls.release() }
}
