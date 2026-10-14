import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import SystemToolsPlugin
@testable import VirtualFoldersPlugin

@Suite struct ConfigPlacesFixSystemTools {
    @Test func aProgramOnThePathBeatsAnApplicationOfTheSameName() throws {
        let box = try Sandbox()
        try box.folder("Apps/mail.app")
        try box.folder("Apps/afmnotaprogram.app")
        try box.file("bin/mail")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: box.url("bin/mail").path)
        #expect(
            TypedCommand.isOnPath("mail", path: box.url("bin").path)
                && !TypedCommand.isOnPath("mail", path: box.url("Apps").path)
        )
        #expect(TypedCommand.isOnPath("sh", path: "/bin:/usr/bin"))
        // A name that no program has still opens the application.
        let app = try #require(TypedCommand("afmnotaprogram"))
        #expect(app.application(relativeTo: box.root, searching: [box.url("Apps")]) != nil)
        // `mail` is a program of the system, so it is left to the shell.
        if TypedCommand.isOnPath("mail") {
            #expect(
                try #require(TypedCommand("mail")).application(relativeTo: box.root, searching: [box.url("Apps")])
                    == nil
            )
        }
        // A path ending in .app is an application whatever the PATH holds.
        #expect(try #require(TypedCommand(box.url("Apps/mail.app").path)).application(relativeTo: box.root) != nil)
    }

    @Test func cancellingEndsAChildThatIgnoresTerminate() {
        let flag = CancellationFlag()
        let runner = ProcessRunner(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; sleep 30 & wait"],
            directory: nil
        )
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.3)
            flag.cancel()
        }
        let started = Date()
        let outcome = runner.run(cancellation: flag)
        #expect(outcome.wasCancelled && Date().timeIntervalSince(started) < 10)
    }
}

@Suite struct ConfigPlacesFixVirtual {
    let fileSystems = FileSystemRegistry()
    let memory = MemoryFileSystem()
    let virtual: VirtualFileSystem

    init() {
        fileSystems.register(LocalFileSystem())
        fileSystems.register(memory)
        virtual = VirtualFileSystem(fileSystems: fileSystems)
        memory.addFile("/A/one.txt")
    }

    @Test func listIdsAreNotSmallNumbersAndMustMatchTheirLocation() throws {
        let url = virtual.register(files: [memory.url("/A/one.txt")], title: "Found", origin: memory.url("/A"))
        guard case .list(let id, _, _)? = VirtualLocation(url) else {
            Issue.record("not a list")
            return
        }
        #expect(id > 100)
        #expect(virtual.entries(of: url)?.count == 1)
        // The same number under another title is not that list.
        let other = VirtualLocation.list(id: id, title: "Other", origin: memory.url("/A")).url
        #expect(virtual.entries(of: other) == nil && virtual.item(at: other) == nil)
        #expect(throws: (any Error).self) { try virtual.list(other, showHidden: false) }
        #expect(try virtual.list(url, showHidden: false).count == 1)
    }

    @Test func evictionSparesAListThatIsShown() {
        let watchable = WatchedSystem()
        fileSystems.register(watchable)
        let first = virtual.register(files: [watchable.url("/d/f")], title: "First", origin: nil)
        let watcher = virtual.watch([first]) { _ in }
        #expect(watcher != nil)
        var later: [URL] = []
        for index in 0..<(VirtualFileSystem.listLimit + 5) {
            later.append(virtual.register(files: [memory.url("/A/one.txt")], title: "L\(index)", origin: nil))
        }
        #expect(virtual.entries(of: first) != nil)
        #expect(virtual.entries(of: later[0]) == nil && virtual.entries(of: later.last!) != nil)
        // Once nobody shows it, it is the oldest and goes.
        _ = watcher
    }

    @MainActor @Test func manyReportsBecomeFewWalks() async throws {
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
        let deadline = Date().addingTimeInterval(30)
        while reports.value < 2, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(reports.value == 2)
        _ = watcher
    }

    @Test func aWalkListsEveryFileOnceAndSkipsMountFolders() throws {
        let box = try Sandbox()
        try box.file("a/one.txt")
        try box.file("a/b/two.txt")
        try box.file("c/three.txt")
        var names: [String] = []
        let walker = BranchWalker(fileSystems: fileSystems, showHidden: false)
        try walker.walk([BranchWalker.Start(box.root)]) {
            names += $0.map(\.name)
            return true
        }
        #expect(names.sorted() == ["a/b/two.txt", "a/one.txt", "c/three.txt"])
        // The same start twice is walked once.
        names = []
        try walker.walk([BranchWalker.Start(box.root), BranchWalker.Start(box.root)]) {
            names += $0.map(\.name)
            return true
        }
        #expect(names.count == 3)
        #expect(BranchWalker.mountFolders.contains("/Volumes") && BranchWalker.mountFolders.contains("/System/Volumes"))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// A file system whose watchers can be fired by hand.
/// Unchecked: its switches are set by the test before use, and it is used from one thread at a time.
private final class WatchedSystem: FileSystemProvider, @unchecked Sendable {
    let scheme = "watched"
    let capabilities: FileSystemCapabilities = []
    private var onChange: (@MainActor @Sendable ([URL]) -> Void)?

    func url(_ path: String) -> URL { URL(string: "watched://" + path)! }
    @MainActor func fire() { onChange?([]) }

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
}
