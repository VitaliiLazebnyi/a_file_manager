public import AFMKernel
public import Foundation

/// The settings that make the file system slow, read-only or awkward.
///
/// A test may change them at any time, also while other threads are inside the file system.
extension MemoryFileSystem {
    /// The settings together; kept in `options`, under its own lock.
    internal struct Options {
        /// See `MemoryFileSystem.capabilities`.
        internal var capabilities: FileSystemCapabilities = [.write]
        /// See `MemoryFileSystem.capabilitiesAt`.
        internal var capabilitiesAt: (@Sendable (URL) -> FileSystemCapabilities)?
        /// See `MemoryFileSystem.copyBlockSize`.
        internal var copyBlockSize = 1 << 20
        /// See `MemoryFileSystem.listBatchSize`.
        internal var listBatchSize: Int?
        /// See `MemoryFileSystem.listBatchDelay`.
        internal var listBatchDelay: TimeInterval = 0
        /// See `MemoryFileSystem.listStartDelay`.
        internal var listStartDelay: TimeInterval = 0
        /// See `MemoryFileSystem.refusesInternalCopy`.
        internal var refusesInternalCopy = false
        /// See `MemoryFileSystem.unreadable`.
        internal var unreadable: Set<String> = []
        /// See `MemoryFileSystem.isLocal`.
        internal var isLocal = true
        /// See `MemoryFileSystem.stallsListings`.
        internal var stallsListings = false
        /// See `MemoryFileSystem.stallsReads`.
        internal var stallsReads = false
        /// See `MemoryFileSystem.stallsWrites`.
        internal var stallsWrites = false
        /// See `MemoryFileSystem.stalledPaths`.
        internal var stalledPaths: Set<String> = []
        /// See `MemoryFileSystem.stallsChanges`.
        internal var stallsChanges = false
        /// See `MemoryFileSystem.quarantineValue`.
        internal var quarantineValue: Data?
        /// See `MemoryFileSystem.commitFailure`.
        internal var commitFailure: (any Error)?
        /// See `MemoryFileSystem.keepsMetadata`.
        internal var keepsMetadata = false
        /// See `MemoryFileSystem.commitSteps`.
        internal var commitSteps = 0
    }

    /// What the file system can do everywhere (`[.write]` to begin with).
    public var capabilities: FileSystemCapabilities {
        get { options.value.capabilities }
        set { options.modify { $0.capabilities = newValue } }
    }

    /// What `capabilities(for:)` answers, by location; nil gives `capabilities` everywhere.
    public var capabilitiesAt: (@Sendable (URL) -> FileSystemCapabilities)? {
        get { options.value.capabilitiesAt }
        set { options.modify { $0.capabilitiesAt = newValue } }
    }

    /// A copy within this file system reports progress in blocks of this size.
    public var copyBlockSize: Int {
        get { options.value.copyBlockSize }
        set { options.modify { $0.copyBlockSize = newValue } }
    }

    /// When set, a directory is listed in batches of this many entries.
    ///
    /// Each batch waits `listBatchDelay` first.
    public var listBatchSize: Int? {
        get { options.value.listBatchSize }
        set { options.modify { $0.listBatchSize = newValue } }
    }

    /// The pause before each batch of `listBatchSize`, like a slow server.
    public var listBatchDelay: TimeInterval {
        get { options.value.listBatchDelay }
        set { options.modify { $0.listBatchDelay = newValue } }
    }

    /// A pause before a listing starts to answer at all, like a server that first has to
    /// collect the whole directory.
    public var listStartDelay: TimeInterval {
        get { options.value.listStartDelay }
        set { options.modify { $0.listStartDelay = newValue } }
    }

    /// When true, the file system cannot copy by itself (two servers, two archives) and the
    /// caller has to stream.
    public var refusesInternalCopy: Bool {
        get { options.value.refusesInternalCopy }
        set { options.modify { $0.refusesInternalCopy = newValue } }
    }

    /// Paths whose listing fails, like a folder without permission.
    public var unreadable: Set<String> {
        get { options.value.unreadable }
        set { options.modify { $0.unreadable = newValue } }
    }

    /// False makes it look like a network share (`VolumeInfo.isLocal`).
    public var isLocal: Bool {
        get { options.value.isLocal }
        set { options.modify { $0.isLocal = newValue } }
    }

    /// When true, a listing that was given a cancellation flag stalls, like a server that has stopped talking.
    ///
    /// It does not answer until the flag is set or `releaseStalls()` is called.
    public var stallsListings: Bool {
        get { options.value.stallsListings }
        set { options.modify { $0.stallsListings = newValue } }
    }

    /// When true, the reads of every reader opened meanwhile stall.
    ///
    /// They do not answer until they are interrupted or `releaseStalls()` is called.
    public var stallsReads: Bool {
        get { options.value.stallsReads }
        set { options.modify { $0.stallsReads = newValue } }
    }

    /// When true, the writes of every writer opened meanwhile stall, as reads do with `stallsReads`.
    public var stallsWrites: Bool {
        get { options.value.stallsWrites }
        set { options.modify { $0.stallsWrites = newValue } }
    }

    /// When not empty, only listings of these paths stall (with `stallsListings`); empty stalls all.
    public var stalledPaths: Set<String> {
        get { options.value.stalledPaths }
        set { options.modify { $0.stalledPaths = newValue } }
    }

    /// When true, the changing calls that were given a cancellation flag (`createDirectory`,
    /// `remove`, `move`, `setAttributes`, `copyMetadata`, `setQuarantine`, `copy`) do not
    /// answer until the flag is set, when they throw `userCancelled` having changed
    /// nothing, or until `releaseStalls()`, when they go on.
    public var stallsChanges: Bool {
        get { options.value.stallsChanges }
        set { options.modify { $0.stallsChanges = newValue } }
    }

    /// The mark `quarantine(of:)` reports for every file; nil for none.
    public var quarantineValue: Data? {
        get { options.value.quarantineValue }
        set { options.modify { $0.quarantineValue = newValue } }
    }

    /// When set, `commit` fails with it.
    public var commitFailure: (any Error)? {
        get { options.value.commitFailure }
        set { options.modify { $0.commitFailure = newValue } }
    }

    /// False makes `copyMetadata` unsupported, as it is by default.
    public var keepsMetadata: Bool {
        get { options.value.keepsMetadata }
        set { options.modify { $0.keepsMetadata = newValue } }
    }

    /// How often a commit asks `progress` before it commits: a commit that takes long, in that many steps.
    ///
    /// 0 asks once, as the protocol's default does.
    public var commitSteps: Int {
        get { options.value.commitSteps }
        set { options.modify { $0.commitSteps = newValue } }
    }

    /// Whether a listing of `path` stalls now.
    internal func stallsListing(of path: String) -> Bool {
        let options = options.value
        return options.stallsListings && (options.stalledPaths.isEmpty || options.stalledPaths.contains(path))
    }
}
