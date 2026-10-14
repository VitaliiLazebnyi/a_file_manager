import AFMKernel
import Foundation
import StressKit
import TestSupport

/// A provider (scheme `stall`) in front of a `MemoryFileSystem` whose questions about single
/// files (`item(at:)`, `volume(of:)`, `totalSize`, `entries`) do not answer
/// while `isStalled` is set, like a share that has stopped talking. Listings stall through the
/// memory file system's own `stallsListings`.
///
/// A call that arrives ON THE MAIN THREAD while stalled is not held (the harness would hang):
/// it is recorded with its stack as "would have frozen the window", and answered.
final class StallFS: FileSystemProvider {
    let inner: MemoryFileSystem
    let scheme = "stall"
    private let gate = NSCondition()
    private var stalled = false
    private var blocked = 0
    private var mostBlocked = 0
    private var blockedBy: [String: Int] = [:]
    var blockedByMethod: String {
        gate.lock()
        defer { gate.unlock() }
        return blockedBy.filter { $0.value > 0 }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(
            separator: ", ")
    }
    private(set) var mainThreadCalls: [String: (count: Int, stack: [String])] = [:]
    private(set) var calls: [String: Int] = [:]

    init() {
        inner = MemoryFileSystem(scheme: "stall")
        inner.isLocal = false
    }

    var isStalled: Bool {
        get {
            gate.lock()
            defer { gate.unlock() }
            return stalled
        }
        set {
            gate.lock()
            stalled = newValue
            gate.broadcast()
            gate.unlock()
            inner.stallsListings = newValue
        }
    }

    func release() {
        isStalled = false
        inner.releaseStalls()
    }

    var blockedNow: Int {
        gate.lock()
        defer { gate.unlock() }
        return blocked
    }
    var mostBlockedAtOnce: Int {
        gate.lock()
        defer { gate.unlock() }
        return mostBlocked
    }

    private func count(_ what: String) {
        gate.lock()
        calls[what, default: 0] += 1
        gate.unlock()
    }

    private func wait(_ what: String, cancellation: CancellationFlag? = nil) {
        gate.lock()
        calls[what, default: 0] += 1
        guard stalled else {
            gate.unlock()
            return
        }
        if Thread.isMainThread {
            var entry = mainThreadCalls[what] ?? (0, Thread.callStackSymbols)
            entry.count += 1
            mainThreadCalls[what] = entry
            gate.unlock()
            return
        }
        gate.unlock()
        let waiting = cancellation?.onCancel { [gate] in
            gate.lock()
            gate.broadcast()
            gate.unlock()
        }
        defer { _ = waiting }
        gate.lock()
        blocked += 1
        blockedBy[what, default: 0] += 1
        mostBlocked = max(mostBlocked, blocked)
        while stalled, cancellation?.isCancelled != true { gate.wait() }
        blocked -= 1
        blockedBy[what, default: 0] -= 1
        gate.unlock()
    }

    var capabilities: FileSystemCapabilities { inner.capabilities }
    // By the protocol `capabilities(for:)` answers at once, from what the provider knows (validation asks
    // it on the main thread at every tick), so a silent server does not hold it up: counted, never stalled.
    func capabilities(for url: URL) -> FileSystemCapabilities {
        count("capabilities(for:)")
        return inner.capabilities(for: url)
    }

    func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        wait("list (no cancellation)")
        return try inner.list(directory, showHidden: showHidden)
    }
    func list(_ directory: URL, showHidden: Bool, receive: ([FileItem]) -> Bool) throws {
        wait("list receive (no cancellation)")
        try inner.list(directory, showHidden: showHidden, receive: receive)
    }
    func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag) throws -> [FileItem] {
        wait("list(cancellation:)", cancellation: cancellation)
        return try inner.list(directory, showHidden: showHidden, cancellation: cancellation)
    }
    func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag, receive: ([FileItem]) -> Bool) throws
    {
        wait("list(cancellation:receive:)", cancellation: cancellation)
        try inner.list(directory, showHidden: showHidden, cancellation: cancellation, receive: receive)
    }
    func entries(of directory: URL, showHidden: Bool, foldersOnly: Bool, cancellation: CancellationFlag) throws
        -> [DirectoryEntry]
    {
        wait("entries(of:)", cancellation: cancellation)
        return try inner.entries(
            of: directory, showHidden: showHidden, foldersOnly: foldersOnly, cancellation: cancellation)
    }
    func item(at url: URL) -> FileItem? {
        wait("item(at:)")
        return inner.item(at: url)
    }
    func item(at url: URL, cancellation: CancellationFlag) -> FileItem? {
        wait("item(at:cancellation:)", cancellation: cancellation)
        return inner.item(at: url)
    }
    func parent(of directory: URL) -> URL? { inner.parent(of: directory) }
    func read(_ url: URL) throws -> FileReader {
        wait("read")
        return try inner.read(url)
    }
    func read(_ url: URL, cancellation: CancellationFlag) throws -> FileReader {
        wait("read(cancellation:)", cancellation: cancellation)
        return try inner.read(url, cancellation: cancellation)
    }
    func createDirectory(at url: URL) throws {
        wait("createDirectory")
        try inner.createDirectory(at: url)
    }
    func write(_ url: URL) throws -> FileWriter {
        wait("write")
        return try inner.write(url)
    }
    func write(_ url: URL, cancellation: CancellationFlag) throws -> FileWriter {
        wait("write(cancellation:)", cancellation: cancellation)
        return try inner.write(url, cancellation: cancellation)
    }
    func append(to url: URL, at offset: Int64?, cancellation: CancellationFlag) throws -> FileWriter {
        wait("append", cancellation: cancellation)
        return try inner.append(to: url, at: offset, cancellation: cancellation)
    }
    func remove(_ url: URL) throws {
        wait("remove")
        try inner.remove(url)
    }
    func trash(_ url: URL) throws {
        wait("trash")
        try inner.trash(url)
    }
    func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        wait("move")
        try inner.move(source, to: destination, replacing: replacing)
    }
    func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        wait("copy")
        try inner.copy(source, to: destination, progress: progress)
    }
    func setAttributes(_ attributes: FileAttributes, of url: URL) throws {
        wait("setAttributes")
        try inner.setAttributes(attributes, of: url)
    }
    func copyMetadata(from source: URL, to destination: URL) throws {
        wait("copyMetadata")
        try inner.copyMetadata(from: source, to: destination)
    }
    func commit(_ url: URL, cancellation: CancellationFlag) throws {
        wait("commit", cancellation: cancellation)
        try inner.commit(url, cancellation: cancellation)
    }
    func quarantine(of url: URL) -> Data? {
        wait("quarantine")
        return inner.quarantine(of: url)
    }
    func setQuarantine(_ value: Data, of url: URL) throws {
        wait("setQuarantine")
        try inner.setQuarantine(value, of: url)
    }
    func displayPath(_ url: URL) -> String { inner.displayPath(url) }
    func location(from text: String) -> URL? { inner.location(from: text) }
    var readsRootedPaths: Bool { inner.readsRootedPaths }
    func places() -> [Place] {
        wait("places")
        return inner.places()
    }
    func volume(of _: URL) -> VolumeInfo? {
        wait("volume(of:)")
        return VolumeInfo(name: "Stalling share", freeBytes: 1 << 30, totalBytes: 1 << 40, isLocal: false)
    }
    func totalSize(of directory: URL, cancellation: CancellationFlag) -> Int64 {
        wait("totalSize", cancellation: cancellation)
        return inner.totalSize(of: directory, cancellation: cancellation)
    }
    func watch(_ directories: [URL], onChange: @escaping ([URL]) -> Void) -> AnyObject? {
        wait("watch")
        return inner.watch(directories, onChange: onChange)
    }

    func snapshotCalls() -> (calls: [String: Int], main: [String: (count: Int, stack: [String])]) {
        gate.lock()
        defer { gate.unlock() }
        return (calls, mainThreadCalls)
    }
}
