import AFMKernel
import Foundation

@testable import NetworkPlugin

/// A session on a server that exists only in memory: a tree of entries by path, and answers
/// the test can change for every call.
///
/// It records the calls it gets.
///
/// Unchecked: everything is guarded by `lock`; the answers are set before use or under it.
internal final class CoverageNetworkSession: RemoteSession, @unchecked Sendable {
    /// What a listing answers.
    internal enum ListAnswer: Sendable {
        /// These entries.
        case listed([RemoteEntry])
        /// The entries the session holds.
        case stored
    }

    /// Writes into nothing and records nothing.
    private final class NullWriter: FileWriter, @unchecked Sendable {
        func write(_: Data) {
            // Dropped.
        }

        func close(attributes _: FileAttributes) {
            // Nothing to finish.
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The profile it was made for.
    internal let profile: ConnectionProfile
    private let lock = NSLock()
    private var entries: [String: RemoteEntry] = [:]
    private var log: [String] = []
    private var connected = true
    private var cheap = true
    private var linkHandler: (@Sendable (String, Bool) -> Void)?
    private var listHook: @Sendable (String) -> ListAnswer = { _ in .stored }
    private var renameHook: @Sendable (String, String) throws -> Void = { _, _ in
        // Every rename goes through.
    }
    private var removeHook: @Sendable (String) throws -> Void = { _ in
        // Every removal goes through.
    }
    private var openWriteFailure: (any Error)?

    /// Whether a login succeeded; tests set it.
    internal var isConnected: Bool {
        get { lock.withLock { connected } }
        set { lock.withLock { connected = newValue } }
    }

    /// Whether one question costs little; tests set it.
    internal var singleLookupsAreCheap: Bool {
        get { lock.withLock { cheap } }
        set { lock.withLock { cheap = newValue } }
    }

    /// The calls, in order: `list /a`, `rename /a /b`, `disconnect`, ….
    internal var calls: [String] { lock.withLock { log } }

    /// An empty server, for `profile`.
    internal init(profile: ConnectionProfile) {
        self.profile = profile
    }

    /// Puts an entry at a path (its name is taken from the path).
    internal func add(_ path: String, isDirectory: Bool, size: Int64) {
        lock.withLock {
            entries[path] = RemoteEntry(name: RemotePath.name(of: path), isDirectory: isDirectory, size: size)
        }
    }

    /// A listing of a folder in place of its entries, or the entries as stored.
    internal func answerLists(with hook: @escaping @Sendable (String) -> ListAnswer) {
        lock.withLock { listHook = hook }
    }

    /// What a rename does besides moving the entry: it may throw.
    internal func answerRenames(with hook: @escaping @Sendable (String, String) throws -> Void) {
        lock.withLock { renameHook = hook }
    }

    /// What a removal does besides removing the entry: it may throw.
    internal func answerRemovals(with hook: @escaping @Sendable (String) throws -> Void) {
        lock.withLock { removeHook = hook }
    }

    /// Makes `openWrite` throw `error`.
    internal func failWrites(with error: any Error) {
        lock.withLock { openWriteFailure = error }
    }

    /// Tells whoever listens that the link at `path` leads to a folder or not.
    internal func resolveLink(_ path: String, isDirectory: Bool) {
        lock.withLock { linkHandler }?(path, isDirectory)
    }

    /// The home folder, `/`.
    internal func connect(cancellation _: CancellationFlag?) -> String {
        record("connect")
        return "/"
    }

    /// The entries below `path`, or what the list hook answers.
    internal func list(
        _ path: String,
        showHidden _: Bool,
        cancellation _: CancellationFlag?,
        receive: ([RemoteEntry]) -> Bool
    ) {
        record("list \(path)")
        let hook = lock.withLock { listHook }
        switch hook(path) {
        case .listed(let listed):
            _ = receive(listed)

        case .stored:
            let stored = lock.withLock {
                entries.filter { RemotePath.parent(of: $0.key) == path }.map(\.value).sorted { $0.name < $1.name }
            }
            _ = receive(stored)
        }
    }

    /// The entry at `path`.
    internal func entry(at path: String, cancellation _: CancellationFlag?) -> RemoteEntry? {
        record("entry \(path)")
        return lock.withLock { entries[path] }
    }

    /// Not used by these tests.
    internal func openRead(_ path: String, cancellation _: CancellationFlag?) throws -> any FileReader {
        throw FileSystemError.notSupported("Reading \(path)")
    }

    /// A writer into nothing; the entry exists at once.
    internal func openWrite(_ path: String, cancellation _: CancellationFlag?) throws -> any FileWriter {
        record("write \(path)")
        if let failure = lock.withLock({ openWriteFailure }) {
            throw failure
        }
        add(path, isDirectory: false, size: 0)
        return NullWriter()
    }

    /// Every file can be continued.
    internal func canAppend(_: String) -> Bool {
        true
    }

    /// A writer into nothing, at the size the entry has.
    internal func openAppend(_ path: String, at offset: Int64?, cancellation _: CancellationFlag?) -> (
        writer: any FileWriter, size: Int64
    ) {
        record("append \(path)")
        let size = offset ?? lock.withLock { entries[path]?.size ?? 0 }
        return (NullWriter(), size)
    }

    /// Keeps the handler for `resolveLink`.
    internal func onLinkResolved(_ handler: @escaping @Sendable (String, Bool) -> Void) {
        lock.withLock { linkHandler = handler }
    }

    /// Adds a folder.
    internal func makeDirectory(_ path: String, cancellation _: CancellationFlag?) {
        record("mkdir \(path)")
        add(path, isDirectory: true, size: 0)
    }

    /// Removes the entry, unless the hook throws.
    internal func remove(_ path: String, kind _: RemovedKind, cancellation _: CancellationFlag?) throws {
        record("remove \(path)")
        try lock.withLock { removeHook }(path)
        lock.withLock { entries[path] = nil }
    }

    /// Moves the entry, unless the hook throws.
    internal func rename(
        _ source: String,
        to destination: String,
        replacing _: Bool,
        cancellation _: CancellationFlag?
    ) throws {
        record("rename \(source) \(destination)")
        try lock.withLock { renameHook }(source, destination)
        lock.withLock {
            var entry = entries.removeValue(forKey: source)
            entry?.name = RemotePath.name(of: destination)
            entries[destination] = entry
        }
    }

    /// Records the call.
    internal func setAttributes(_: FileAttributes, of path: String, cancellation _: CancellationFlag?) {
        record("attributes \(path)")
    }

    /// Records the call.
    internal func disconnect() {
        record("disconnect")
    }

    private func record(_ call: String) {
        lock.withLock { log.append(call) }
    }

    deinit {
        // Nothing to release.
    }
}
