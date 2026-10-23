import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import VirtualFoldersPlugin

/// Lists of the virtual file system: their ids, their eviction, their watchers and the walk.
@Suite
internal struct ConfigPlacesFixVirtual {
    /// Counts reports from any thread; guarded by `lock`.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        deinit {
            // Nothing to release.
        }
    }

    /// A file system whose watchers can be fired by hand.
    ///
    /// Unchecked: its switches are set by the test before use, and it is used from one thread at a
    /// time.
    private final class WatchedSystem: FileSystemProvider, @unchecked Sendable {
        let scheme = "watched"
        let capabilities: FileSystemCapabilities = []
        private var onChange: (@MainActor @Sendable ([URL]) -> Void)?

        func url(_ path: String) -> URL {
            var components = URLComponents()
            components.scheme = scheme
            components.host = ""
            components.path = path
            guard let url = components.url else {
                preconditionFailure("\(path) is not a path")
            }
            return url
        }

        @MainActor
        func fire() { onChange?([]) }

        func list(_: URL, showHidden _: Bool) -> [FileItem] { [] }
        func item(at url: URL) -> FileItem? { FileItem(url: url, name: url.lastPathComponent) }
        func parent(of directory: URL) -> URL? { directory.path == "/" ? nil : directory.deletingLastPathComponent() }
        func read(_: URL) throws -> any FileReader { throw FileSystemError.notSupported("Reading") }
        func createDirectory(at _: URL) throws { throw FileSystemError.notSupported("Writing") }
        func write(_: URL) throws -> any FileWriter { throw FileSystemError.notSupported("Writing") }
        func remove(_: URL) throws { throw FileSystemError.notSupported("Writing") }
        func move(_: URL, to _: URL, replacing _: Bool) throws {
            throw FileSystemError.notSupported("Writing")
        }
        func copy(_: URL, to _: URL, progress _: (Int64) -> Bool) throws {
            throw FileSystemError.notSupported("Writing")
        }
        func watch(_: [URL], onChange: @escaping @MainActor @Sendable ([URL]) -> Void) -> (any WatchToken)? {
            self.onChange = onChange
            return self
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The local file system and `memory`.
    internal let fileSystems = FileSystemRegistry()
    /// Holds the files the lists name.
    internal let memory = MemoryFileSystem()
    /// The file system under test.
    internal let virtual: VirtualFileSystem

    /// A virtual file system over a memory tree with one file.
    internal init() {
        fileSystems.register(LocalFileSystem())
        fileSystems.register(memory)
        virtual = VirtualFileSystem(fileSystems: fileSystems)
        memory.addFile("/A/one.txt")
    }

    /// A list id is a large number, and a location with that id but another title is not the list.
    @Test
    internal func listIdsAreNotSmallNumbersAndMustMatchTheirLocation() throws {
        let url = virtual.register(files: [memory.url("/A/one.txt")], title: "Found", origin: memory.url("/A"))
        guard case .list(let id, _, _)? = VirtualLocation(url) else {
            Issue.record("not a list")
            return
        }
        #expect(id > 100)
        #expect(virtual.entries(of: url).count == 1)
        // The same number under another title is not that list.
        let other = VirtualLocation.list(id: id, title: "Other", origin: memory.url("/A")).url
        #expect(virtual.entries(of: other).isEmpty && virtual.item(at: other) == nil)
        #expect(throws: (any Error).self) { try virtual.list(other, showHidden: false) }
        #expect(try virtual.list(url, showHidden: false).count == 1)
    }

    /// Registering many lists forgets the oldest ones, but not one that is watched.
    @Test
    internal func evictionSparesAListThatIsShown() throws {
        let watchable = WatchedSystem()
        fileSystems.register(watchable)
        let first = virtual.register(files: [watchable.url("/d/f")], title: "First", origin: nil)
        let watcher = virtual.watch([first]) { _ in
            // Only the watching itself counts here.
        }
        #expect(watcher != nil)
        var later: [URL] = []

        for index in 0..<(VirtualFileSystem.listLimit + 5) {
            later.append(virtual.register(files: [memory.url("/A/one.txt")], title: "L\(index)", origin: nil))
        }
        #expect(!virtual.entries(of: first).isEmpty)
        let newest = try #require(later.last)
        #expect(virtual.entries(of: later[0]).isEmpty && !virtual.entries(of: newest).isEmpty)
        // Once nobody shows it, it is the oldest and goes.
        _ = watcher
    }

    /// A hundred reports of the real file system reach the caller as two.
    @MainActor
    @Test
    internal func manyReportsBecomeFewWalks() async throws {
        let watchable = WatchedSystem()
        let registry = FileSystemRegistry()
        registry.register(watchable)
        let fileSystem = VirtualFileSystem(fileSystems: registry)
        let list = fileSystem.register(files: [watchable.url("/d/f")], title: "L", origin: nil)
        let reports = Counter()
        let watcher = fileSystem.watch([list]) { _ in reports.increment() }
        for _ in 0..<100 { watchable.fire() }
        // Reports reach the caller on the main thread: wait for the main queue.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        // One report at once; the window may already have passed on a busy machine, which adds the second.
        #expect((1...2).contains(reports.value))
        // The rest comes as one more report once the window has passed (the timer runs at the
        // pace of a busy machine, so it is waited for rather than timed).
        let deadline = Date().addingTimeInterval(Wait.ceiling)
        while reports.value < 2, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(reports.value == 2)
        _ = watcher
    }

    /// A walk lists every file once, also from the same start given twice, and never enters a mount folder.
    @Test
    internal func aWalkListsEveryFileOnceAndSkipsMountFolders() throws {
        let box = try Sandbox()
        try box.file("a/one.txt")
        try box.file("a/b/two.txt")
        try box.file("c/three.txt")
        var names: [String] = []
        let walker = BranchWalker(fileSystems: fileSystems, showHidden: false)
        try walker.walk([BranchWalker.Start(box.root)]) { batch in
            names += batch.map(\.name)
            return true
        }
        #expect(names.sorted() == ["a/b/two.txt", "a/one.txt", "c/three.txt"])
        // The same start twice is walked once.
        names = []
        try walker.walk([BranchWalker.Start(box.root), BranchWalker.Start(box.root)]) { batch in
            names += batch.map(\.name)
            return true
        }
        #expect(names.count == 3)
        #expect(BranchWalker.mountFolders.contains("/Volumes") && BranchWalker.mountFolders.contains("/System/Volumes"))
    }
}
