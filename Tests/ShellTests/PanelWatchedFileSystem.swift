import AFMKernel
import Foundation
import TestSupport

/// A file system whose `watch` and `places` say on which thread they were called, and whose `watch`
/// can be made to wait like a share that has stopped answering.
///
/// Everything else is a memory file system's.
///
/// Unchecked: what it records is guarded by `condition`; its switches are set by the test before use.
internal final class PanelWatchedFileSystem: FileSystemProvider, @unchecked Sendable {
    /// A watch handed out: when it is let go of, the file system counts it.
    private final class Token: WatchToken, Sendable {
        let onEnd: @Sendable () -> Void

        init(onEnd: @escaping @Sendable () -> Void) {
            self.onEnd = onEnd
        }

        deinit {
            onEnd()
        }
    }

    /// The memory file system that answers everything but watching and places.
    internal let inner = MemoryFileSystem(scheme: "watched")
    private let condition = NSCondition()
    private var holds = false
    private var ejectable = false
    private var isServer = false
    private var extraPlaces: [Place] = []
    private var watchCalls: [(path: String, onMain: Bool)] = []
    private var placeCalls: [Bool] = []
    private var living = 0
    private var ended = 0
    private var handlers: [String: @MainActor @Sendable ([URL]) -> Void] = [:]

    /// While true, `watch` does not come back.
    internal var holdsWatches: Bool {
        get { condition.withLock { holds } }
        set {
            condition.withLock {
                holds = newValue
                condition.broadcast()
            }
        }
    }

    /// The folders `watch` was asked for, and whether on the main thread.
    internal var watches: [(path: String, onMain: Bool)] { condition.withLock { watchCalls } }
    /// Whether each question for the places came on the main thread.
    internal var placesAskedOnMain: [Bool] { condition.withLock { placeCalls } }
    /// Watches that were handed out and not let go of yet.
    internal var livingWatches: Int { condition.withLock { living } }
    /// Watches that were let go of.
    internal var endedWatches: Int { condition.withLock { ended } }
    /// The memory file system's scheme, `watched`.
    internal var scheme: String { inner.scheme }
    /// The memory file system's capabilities.
    internal var capabilities: FileSystemCapabilities { inner.capabilities }
    /// Whether its place is a drive that can be ejected; false at first.
    internal var placeCanBeEjected: Bool {
        get { condition.withLock { ejectable } }
        set { condition.withLock { ejectable = newValue } }
    }
    /// Places it names besides its own; none at first.
    internal var morePlaces: [Place] {
        get { condition.withLock { extraPlaces } }
        set { condition.withLock { extraPlaces = newValue } }
    }
    /// Whether it says it is on a server (`connectsToServer`); false at first.
    internal var connectsToServer: Bool {
        get { condition.withLock { isServer } }
        set { condition.withLock { isServer = newValue } }
    }

    /// A file system that has been asked nothing.
    internal init() {
        // Nothing asked yet.
    }

    /// The location of `path`.
    internal func url(_ path: String) -> URL {
        inner.url(path)
    }

    /// Reports a change of a watched folder, as the file system would: on the main thread.
    @MainActor
    internal func reportChange(of path: String) {
        let handler = condition.withLock { handlers[path] }
        handler?([url(path)])
    }

    /// Notes the call, waits while watches are held, and hands out a counted watch.
    internal func watch(_ directories: [URL], onChange: @escaping @MainActor @Sendable ([URL]) -> Void) -> (
        any WatchToken
    )? {
        condition.withLock {
            for directory in directories {
                watchCalls.append((directory.path, Thread.isMainThread))
            }
            while holds {
                condition.wait()
            }
            living += 1
            for directory in directories {
                handlers[directory.path] = onChange
            }
        }
        return Token { [weak self] in self?.watchEnded() }
    }

    /// One place, noting on which thread it was asked for.
    internal func places() -> [Place] {
        condition.withLock { placeCalls.append(Thread.isMainThread) }
        return [Place(name: "Watched", url: url("/"), kind: .externalDisk, canBeEjected: placeCanBeEjected)]
            + morePlaces
    }

    /// The memory file system's listing.
    internal func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try inner.list(directory, showHidden: showHidden)
    }

    /// The memory file system's listing in batches.
    internal func list(
        _ directory: URL,
        showHidden: Bool,
        cancellation: CancellationFlag,
        receive: ([FileItem]) -> Bool
    )
        throws
    {
        try inner.list(directory, showHidden: showHidden, cancellation: cancellation, receive: receive)
    }

    /// The memory file system's volume.
    internal func volume(of url: URL) -> VolumeInfo? {
        inner.volume(of: url)
    }

    /// The memory file system's entry.
    internal func item(at url: URL) -> FileItem? {
        inner.item(at: url)
    }

    /// The memory file system's parent.
    internal func parent(of directory: URL) -> URL? {
        inner.parent(of: directory)
    }

    /// The memory file system's reader.
    internal func read(_ url: URL) throws -> any FileReader {
        try inner.read(url)
    }

    /// Makes a folder in the memory file system.
    internal func createDirectory(at url: URL) {
        inner.createDirectory(at: url)
    }

    /// The memory file system's writer.
    internal func write(_ url: URL) throws -> any FileWriter {
        try inner.write(url)
    }

    /// Removes from the memory file system.
    internal func remove(_ url: URL) throws {
        try inner.remove(url)
    }

    /// Moves in the memory file system.
    internal func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try inner.move(source, to: destination, replacing: replacing)
    }

    /// Copies in the memory file system.
    internal func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try inner.copy(source, to: destination, progress: progress)
    }

    /// A watch was let go of.
    private func watchEnded() {
        condition.withLock {
            living -= 1
            ended += 1
        }
    }

    deinit {
        // Nothing to release.
    }
}
