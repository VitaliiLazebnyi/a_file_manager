import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import LocalFileSystemPlugin

/// Waits for a condition, not for a length of time; false only after a very long while.
private func waitUntil(seconds: TimeInterval = Wait.ceiling, _ condition: () -> Bool) -> Bool {
    let end = Date(timeIntervalSinceNow: seconds)
    while !condition() {
        if Date() > end {
            return false
        }
        usleep(2_000)
    }
    return true
}

/// Runs `body` on a thread of its own and hands back what it returned or threw, when it is over.
///
/// Unchecked: the result is guarded by `condition`.
private final class Running<Value>: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<Value, any Error>?

    var isOver: Bool {
        condition.lock()
        defer { condition.unlock() }
        return result != nil
    }

    init(_ body: @escaping @Sendable () throws -> Value) {
        Thread.detachNewThread { [self] in
            let result = Result { try body() }
            condition.lock()
            self.result = result
            condition.broadcast()
            condition.unlock()
        }
    }

    /// Nil when it did not end for a very long time: a hang, reported as a failure.
    func wait(seconds: TimeInterval = Wait.ceiling) -> Result<Value, any Error>? {
        let end = Date(timeIntervalSinceNow: seconds)
        condition.lock()
        defer { condition.unlock() }
        while result == nil, condition.wait(until: end) {}
        return result
    }
}

private func wasCancelled<Value>(_ result: Result<Value, any Error>?) -> Bool {
    guard case .failure(let error)? = result else {
        return false
    }
    return (error as? CocoaError)?.code == .userCancelled
}

/// A folder that stands for a share whose server has gone: every question the file system
/// puts to the system about a path in it waits here until the "server" answers again.
///
/// The folder itself is an ordinary one on the local disk. Unchecked: the state is guarded by
/// `condition`.
private final class DeadVolume: @unchecked Sendable {
    let root: String
    private let condition = NSCondition()
    private var answers = false
    private var waitingNow = 0
    private var askedSoFar = 0

    /// How many questions are waiting at this moment, and how many were ever put.
    var waiting: Int {
        condition.lock()
        defer { condition.unlock() }
        return waitingNow
    }
    var asked: Int {
        condition.lock()
        defer { condition.unlock() }
        return askedSoFar
    }

    init(_ root: URL) { self.root = root.path }

    func holds(_ path: String) -> Bool { path == root || path.hasPrefix(root + "/") }

    func willAsk(_ path: String) {
        guard holds(path) else {
            return
        }
        condition.lock()
        askedSoFar += 1
        waitingNow += 1
        while !answers { condition.wait() }
        waitingNow -= 1
        condition.unlock()
    }

    /// The server is back: everything that waits goes on, and nothing waits from now on.
    func answer() {
        condition.lock()
        answers = true
        condition.broadcast()
        condition.unlock()
    }

    /// A file system that takes the folder for a volume that is not a disk of this Mac.
    func fileSystem(patienceAfterCancel: TimeInterval = 0.2, volumePatience: TimeInterval = 0.3) -> LocalFileSystem {
        var probes = LocalProbes()
        probes.willAsk = { [self] in willAsk($0) }
        probes.isLocal = { [self] in holds($0) ? false : nil }
        probes.patienceAfterCancel = patienceAfterCancel
        probes.volumePatience = volumePatience
        return LocalFileSystem(probes: probes)
    }
}

/// Review 2, second pass: what the local file system says about its entries, and its changes
/// for callers that hold a cancellation flag.
@Suite
internal struct Review2KernelP2LocalItems {
    internal let local = LocalFileSystem()

    @Test
    internal func aLinkToAFileSaysHowLargeThatFileIs() throws {
        let box = try Sandbox()
        try box.file("big.bin", "12345")
        try box.folder("folder")
        try FileManager.default.createSymbolicLink(atPath: box.url("to-file").path, withDestinationPath: "big.bin")
        try FileManager.default.createSymbolicLink(atPath: box.url("to-folder").path, withDestinationPath: "folder")
        try FileManager.default.createSymbolicLink(atPath: box.url("to-nothing").path, withDestinationPath: "missing")
        let listed = Dictionary(
            uniqueKeysWithValues: try local.list(box.root, showHidden: true).map { ($0.name, $0) }
        )
        // The link itself has no size (the entry is what `lstat` sees); the file's is said besides.
        #expect(
            listed["to-file"]?.size == 0 && listed["to-file"]?.linkTargetSize == 5
                && listed["to-file"]?.isSymlink == true
        )
        #expect(listed["to-folder"]?.linkTargetSize == nil && listed["to-folder"]?.isDirectory == true)
        #expect(
            listed["to-nothing"]?.linkTargetSize == nil && listed["big.bin"]?.linkTargetSize == nil
                && listed["big.bin"]?.size == 5
        )
        // Asked one by one, the same.
        for name in ["to-file", "to-folder", "to-nothing", "big.bin", "folder"] {
            #expect(local.item(at: box.root.appending(name: name)) == listed[name], "\(name)")
        }
        // The figure is the target's as it was when the entry was read: read again, it follows.
        try "1234567890".write(to: box.url("big.bin"), atomically: false, encoding: .utf8)
        #expect(local.item(at: box.url("to-file"))?.linkTargetSize == 10)
    }

    @Test
    internal func theTopOfEveryLocalLocationIsKnownWithoutGoingUp() {
        let deep = URL(fileURLWithPath: "/" + (0..<300).map { "d\($0)" }.joined(separator: "/"))
        #expect(local.root(of: deep).path == "/" && local.root(of: URL(fileURLWithPath: "/")).path == "/")
        // What going up gives, which is what the kernel did before.
        var climbed = deep
        while let parent = local.parent(of: climbed) { climbed = parent }
        #expect(local.root(of: deep).isSameLocation(as: climbed))
    }
}

@Suite
internal struct Review2KernelP2LocalChanges {
    internal let local = LocalFileSystem()

    // MARK: L029 — a folder that must be new

    @Test
    internal func aFolderThatMustBeNewIsMadeOnlyWhereNothingHasItsName() throws {
        let box = try Sandbox()
        // Missing parents are made as usual; the last name must be free.
        try local.createDirectory(at: box.url("a/b/new"), exclusive: true)
        #expect(local.item(at: box.url("a/b/new"))?.isRealDirectory == true)
        #expect(throws: FileSystemError.self) { try local.createDirectory(at: box.url("a/b/new"), exclusive: true) }
        // A file of that name, and a link to a folder: both are "something is there".
        try box.file("a/file")
        #expect(throws: FileSystemError.self) { try local.createDirectory(at: box.url("a/file"), exclusive: true) }
        let outside = try box.folder("outside")
        try FileManager.default.createSymbolicLink(at: box.url("a/link"), withDestinationURL: outside)
        #expect(throws: FileSystemError.self) { try local.createDirectory(at: box.url("a/link"), exclusive: true) }
        // A dangling link has the name too, and nothing is made where it points.
        try FileManager.default.createSymbolicLink(
            atPath: box.url("a/dangling").path,
            withDestinationPath: box.url("elsewhere").path
        )
        #expect(throws: FileSystemError.self) { try local.createDirectory(at: box.url("a/dangling"), exclusive: true) }
        let inside = try FileManager.default.contentsOfDirectory(atPath: outside.path)
        #expect(!box.exists("elsewhere") && inside.isEmpty)
        // Through the protocol, with a flag.
        let provider: any FileSystemProvider = local
        try provider.createDirectory(at: box.url("c/new"), exclusive: true, cancellation: CancellationFlag())
        #expect(throws: FileSystemError.self) {
            try provider.createDirectory(at: box.url("c/new"), exclusive: true, cancellation: CancellationFlag())
        }
    }

    @Test
    internal func aFolderThatMayBeThereIsMadeAsBefore() throws {
        let box = try Sandbox()
        // The plain call keeps its contract: an existing folder, or a link to one, is success.
        try local.createDirectory(at: box.url("x/y/z"))
        try local.createDirectory(at: box.url("x/y/z"))
        try local.createDirectory(at: box.url("x/y/z"), exclusive: false)
        let outside = try box.folder("outside")
        try FileManager.default.createSymbolicLink(at: box.url("x/link"), withDestinationURL: outside)
        try local.createDirectory(at: box.url("x/link"))
        try local.createDirectory(at: box.url("x/link/below/deeper"))
        #expect(box.exists("outside/below/deeper"))
        // A file in the way is an error, whether it has the name or lies on the way to it.
        try box.file("x/file")
        #expect(throws: (any Error).self) { try local.createDirectory(at: box.url("x/file")) }
        #expect(throws: (any Error).self) { try local.createDirectory(at: box.url("x/file/below")) }
        #expect(box.read("x/file") == "x")
        // The rights are what the system gives a new folder.
        var (made, reference) = (stat(), stat())
        try FileManager.default.createDirectory(at: box.url("reference"), withIntermediateDirectories: true)
        #expect(lstat(box.url("x/y/z").path, &made) == 0 && lstat(box.url("reference").path, &reference) == 0)
        #expect(made.st_mode == reference.st_mode)
        // The root, and a path with a slash at its end.
        try local.createDirectory(at: URL(fileURLWithPath: "/"))
        try local.createDirectory(at: URL(fileURLWithPath: box.url("slash").path + "/", isDirectory: true))
        #expect(box.exists("slash"))
    }

    @Test
    internal func manyThreadsMakeTheSameFoldersAtOnce() throws {
        let box = try Sandbox()
        let failures = Locked(0)
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            do { try local.createDirectory(at: box.url("shared/a/b/c/leaf\(index % 4)")) } catch {
                failures.withValue { $0 += 1 }
            }
        }
        #expect(failures.withValue { $0 } == 0)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: box.url("shared/a/b/c").path).sorted() == [
                "leaf0", "leaf1", "leaf2", "leaf3"
            ]
        )
        // Of many that want the same new folder, one gets it.
        let made = Locked(0)
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if (try? local.createDirectory(at: box.url("shared/only"), exclusive: true)) != nil {
                made.withValue { $0 += 1 }
            }
        }
        #expect(made.withValue { $0 } == 1)
    }

    // MARK: F043 — deleting inside a tree whose folders may be swapped for links

    @Test
    internal func anItemOfATreeIsRemovedOnlyWhereTheTreeReallyIs() throws {
        let box = try Sandbox()
        try box.file("tree/sub/deep/a.txt")
        try box.file("tree/sub/b.txt")
        try box.file("tree/top.txt")
        try box.file("victim/deep/a.txt", "precious")
        try box.file("victim/b.txt", "precious")
        let (root, flag) = (box.url("tree"), CancellationFlag())
        // As long as the tree is what it was, items go at any depth, files and empty folders.
        try local.remove(box.url("tree/top.txt"), below: root, cancellation: flag)
        try local.remove(box.url("tree/sub/deep/a.txt"), below: root, cancellation: flag)
        try local.remove(box.url("tree/sub/deep"), below: root, cancellation: flag)
        #expect(!box.exists("tree/top.txt") && !box.exists("tree/sub/deep") && box.exists("tree/sub/b.txt"))
        // A folder of the tree is swapped for a link to somebody else's folder, after it was listed.
        try FileManager.default.moveItem(at: box.url("tree/sub"), to: box.url("aside"))
        try FileManager.default.createSymbolicLink(at: box.url("tree/sub"), withDestinationURL: box.url("victim"))
        #expect(throws: (any Error).self) {
            try local.remove(box.url("tree/sub/b.txt"), below: root, cancellation: flag)
        }
        #expect(throws: (any Error).self) {
            try local.remove(box.url("tree/sub/deep/a.txt"), below: root, cancellation: flag)
        }
        #expect(throws: (any Error).self) {
            try local.remove(box.url("tree/sub/deep"), below: root, cancellation: flag)
        }
        #expect(box.read("victim/b.txt") == "precious" && box.read("victim/deep/a.txt") == "precious")
        // The link itself is an entry of the tree like any other, and goes as a link.
        try local.remove(box.url("tree/sub"), below: root, cancellation: flag)
        #expect(!box.exists("tree/sub") && box.read("victim/b.txt") == "precious")
        // The top swapped for a link: nothing below it is touched through the link.
        try box.file("tree2/x.txt")
        try FileManager.default.moveItem(at: box.url("tree2"), to: box.url("aside2"))
        try FileManager.default.createSymbolicLink(at: box.url("tree2"), withDestinationURL: box.url("victim"))
        #expect(throws: (any Error).self) {
            try local.remove(box.url("tree2/b.txt"), below: box.url("tree2"), cancellation: flag)
        }
        #expect(box.read("victim/b.txt") == "precious")
        // Not below the root at all, by a path that only looks as if it were: refused.
        #expect(throws: (any Error).self) {
            try local.remove(box.url("tree/../victim/b.txt"), below: root, cancellation: flag)
        }
        #expect(throws: (any Error).self) { try local.remove(box.url("treeish"), below: root, cancellation: flag) }
        #expect(throws: (any Error).self) { try local.remove(root, below: root, cancellation: flag) }
        #expect(box.read("victim/b.txt") == "precious")
        // A folder that is not empty stays, as with the plain call; a set flag begins nothing.
        try box.file("tree/full/in.txt")
        #expect(throws: (any Error).self) { try local.remove(box.url("tree/full"), below: root, cancellation: flag) }
        let set = CancellationFlag()
        set.cancel()
        #expect(throws: CocoaError.self) {
            try local.remove(box.url("tree/full/in.txt"), below: root, cancellation: set)
        }
        #expect(box.exists("tree/full/in.txt"))
    }

    // MARK: L023 — the changing calls with a flag, on a disk of this Mac

    @Test
    internal func theChangingCallsWorkWithAFlagAsWithout() throws {
        let box = try Sandbox()
        let flag = CancellationFlag()
        try local.createDirectory(at: box.url("made/inner"), cancellation: flag)
        try box.file("made/a.txt", "abc")
        try local.move(box.url("made/a.txt"), to: box.url("made/b.txt"), replacing: false, cancellation: flag)
        #expect(!box.exists("made/a.txt") && box.read("made/b.txt") == "abc")
        try box.file("made/c.txt", "taken")
        #expect(throws: FileSystemError.self) {
            try local.move(box.url("made/b.txt"), to: box.url("made/c.txt"), replacing: false, cancellation: flag)
        }
        try local.move(box.url("made/b.txt"), to: box.url("made/c.txt"), replacing: true, cancellation: flag)
        #expect(box.read("made/c.txt") == "abc")
        let date = Date(timeIntervalSince1970: 1_500_000_000)
        try local.setAttributes(
            FileAttributes(modified: date, permissions: 0o640),
            of: box.url("made/c.txt"),
            cancellation: flag
        )
        let item = try #require(local.item(at: box.url("made/c.txt")))
        #expect(item.modified == date && item.permissions == 0o640)
        let mark = Data("0081;65f0a1b2;Safari;".utf8)
        try local.setQuarantine(mark, of: box.url("made/c.txt"), cancellation: flag)
        #expect(local.quarantine(of: box.url("made/c.txt")) == mark)
        try box.file("made/d.txt", "d")
        let tag = Data("red".utf8)
        #expect(
            tag.withUnsafeBytes {
                setxattr(box.url("made/c.txt").path, "afm.test.tag", $0.baseAddress, $0.count, 0, 0)
            } == 0
        )
        try local.copyMetadata(from: box.url("made/c.txt"), to: box.url("made/d.txt"), cancellation: flag)
        var carried = [UInt8](repeating: 0, count: 16)
        let length = getxattr(box.url("made/d.txt").path, "afm.test.tag", &carried, carried.count, 0, 0)
        #expect(length == 3 && Data(carried.prefix(3)) == tag)
        var reported: [Int64] = []
        try local.copy(box.url("made/c.txt"), to: box.url("made/e.txt"), cancellation: flag) {
            reported.append($0)
            return true
        }
        #expect(box.read("made/e.txt") == "abc" && local.item(at: box.url("made/e.txt"))?.modified == date)
        #expect(throws: FileSystemError.self) {
            try local.copy(box.url("made/c.txt"), to: box.url("made/e.txt"), cancellation: flag) { _ in true }
        }
        for name in ["c.txt", "d.txt", "e.txt", "inner"] {
            try local.remove(box.url("made/" + name), cancellation: flag)
        }
        try local.remove(box.url("made"), cancellation: flag)
        #expect(!box.exists("made"))
        // What fails without a flag fails the same way with one.
        #expect(throws: (any Error).self) { try local.remove(box.url("missing"), cancellation: flag) }
        try box.file("full/in.txt")
        #expect(throws: (any Error).self) { try local.remove(box.url("full"), cancellation: flag) }
        #expect(box.exists("full/in.txt"))
    }

    @Test
    internal func aFlagThatIsSetKeepsEveryChangeFromBeingBegun() throws {
        let box = try Sandbox()
        try box.file("a.txt", "abc")
        let before = try #require(local.item(at: box.url("a.txt")))
        let flag = CancellationFlag()
        flag.cancel()
        func stopped(_ change: () throws -> Void) -> Bool {
            do { try change() } catch { return (error as? CocoaError)?.code == .userCancelled }
            return false
        }
        #expect(stopped { try local.createDirectory(at: box.url("new"), cancellation: flag) })
        #expect(stopped { try local.createDirectory(at: box.url("new"), exclusive: true, cancellation: flag) })
        #expect(stopped { try local.remove(box.url("a.txt"), cancellation: flag) })
        #expect(
            stopped { try local.move(box.url("a.txt"), to: box.url("b.txt"), replacing: true, cancellation: flag) }
        )
        #expect(
            stopped {
                try local.setAttributes(
                    FileAttributes(modified: Date(), permissions: 0o600),
                    of: box.url("a.txt"),
                    cancellation: flag
                )
            }
        )
        #expect(stopped { try local.setQuarantine(Data("0081;0;x;".utf8), of: box.url("a.txt"), cancellation: flag) })
        #expect(stopped { try local.copyMetadata(from: box.url("a.txt"), to: box.url("a.txt"), cancellation: flag) })
        var asked = 0
        #expect(
            stopped {
                try local.copy(box.url("a.txt"), to: box.url("c.txt"), cancellation: flag) { _ in
                    asked += 1
                    return true
                }
            }
        )
        #expect(asked == 0 && local.volume(of: box.root, cancellation: flag) == nil)
        // Nothing was touched.
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.root.path) == ["a.txt"])
        #expect(local.item(at: box.url("a.txt")) == before && local.quarantine(of: box.url("a.txt")) == nil)
    }

    @Test
    internal func aLockThatWasTakenOffForAChangeIsPutBackWhenTheChangeIsStopped() throws {
        let box = try Sandbox()
        let file = try box.file("locked.txt")
        #expect(chflags(file.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(file.path, 0) }
        // The flag is set by the system's own hand between two steps: after the lock is off
        // (the first step that waits on the volume) and before the date is set.
        let flag = CancellationFlag()
        // Used by the callbacks, which run one at a time while the calls below wait for them.
        nonisolated(unsafe) var steps = 0
        var probes = LocalProbes()
        probes.willAsk = { path in
            guard path == file.path else {
                return
            }
            steps += 1
            // 1: looking at the item, 2: taking the lock off, 3: setting the date.
            if steps == 3 { flag.cancel() }
        }
        let stopping = LocalFileSystem(probes: probes)
        var failure: (any Error)?
        do {
            try stopping.setAttributes(
                FileAttributes(modified: Date(timeIntervalSince1970: 1_000_000), permissions: 0o644),
                of: file,
                cancellation: flag
            )
        } catch { failure = error }
        #expect((failure as? CocoaError)?.code == .userCancelled && steps == 3)
        var st = stat()
        #expect(lstat(file.path, &st) == 0 && st.st_flags & UInt32(UF_IMMUTABLE) != 0)
        #expect(
            Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)) != Date(timeIntervalSince1970: 1_000_000)
        )
    }

    @Test
    internal func aCopyIsStoppedBetweenTheStepsTheSystemReports() throws {
        let box = try Sandbox()
        // Large enough for the system to report progress where it copies block by block.
        let source = box.url("source.bin")
        let data = Data(repeating: 7, count: 8 << 20)
        try data.write(to: source)
        let flag = CancellationFlag()
        var reports = 0
        var failure: (any Error)?
        do {
            try local.copy(source, to: box.url("copy.bin"), cancellation: flag) { _ in
                reports += 1
                flag.cancel()
                return true
            }
        } catch { failure = error }
        // Where the volume clones (the Mac's own disks do), no progress is reported and the
        // copy is there at once; where it copies block by block, the flag stopped it and
        // nothing is left. Either is right; a half-written file under the final name is not.
        if reports == 0 {
            #expect(failure == nil && (try? Data(contentsOf: box.url("copy.bin"))) == data)
        } else {
            #expect((failure as? CocoaError)?.code == .userCancelled && !box.exists("copy.bin"))
        }
    }
}

/// A share whose server has gone, stood in for by a folder whose questions do not come back.
@Suite
internal struct Review2KernelP2DeadVolume {
    @Test
    internal func aChangeOnAVolumeThatDoesNotAnswerIsLeftBehindWhenItsFlagIsSet() throws {
        let box = try Sandbox()
        let dead = DeadVolume(try box.folder("share"))
        try box.file("share/a.txt", "a")
        try box.file("here/b.txt", "b")
        let local = dead.fileSystem()
        let flag = CancellationFlag()
        let removal = Running { try local.remove(box.url("share/a.txt"), cancellation: flag) }
        #expect(waitUntil { dead.waiting == 1 })
        #expect(!removal.isOver)
        // Meanwhile the disks that answer are served as ever, with a flag and without.
        try local.remove(box.url("here/b.txt"), cancellation: CancellationFlag())
        try local.createDirectory(at: box.url("here/new"))
        #expect(!box.exists("here/b.txt") && box.exists("here/new"))
        // Cancel: the caller is free after the moment the call is given to come back.
        flag.cancel()
        #expect(wasCancelled(removal.wait()))
        #expect(
            RemoteChanges.shared.strandedCalls(on: dead.root) == 1 && dead.waiting == 1 && box.exists("share/a.txt")
        )
        // The server answers again: the call that was left behind makes no further step.
        dead.answer()
        #expect(waitUntil { RemoteChanges.shared.strandedCalls(on: dead.root) == 0 })
        #expect(box.exists("share/a.txt"))
        // And the volume is served again.
        try local.remove(box.url("share/a.txt"), cancellation: CancellationFlag())
        #expect(!box.exists("share/a.txt"))
    }

    @Test
    internal func aVolumeWithSeveralCallsLeftBehindIsNotAskedAgainUntilOneReturns() throws {
        let box = try Sandbox()
        let dead = DeadVolume(try box.folder("share"))
        let local = dead.fileSystem(patienceAfterCancel: 0.05)
        for index in 0..<RemoteChanges.limit {
            let flag = CancellationFlag()
            let making = Running { try local.createDirectory(at: box.url("share/new\(index)"), cancellation: flag) }
            #expect(waitUntil { dead.waiting == index + 1 })
            flag.cancel()
            #expect(wasCancelled(making.wait()))
        }
        #expect(RemoteChanges.shared.strandedCalls(on: dead.root) == RemoteChanges.limit)
        // The next one is refused at once, without a thread and without a question.
        let asked = dead.asked
        let refused = Running {
            try local.createDirectory(at: box.url("share/more"), cancellation: CancellationFlag())
        }
        guard case .failure(let error)? = refused.wait() else {
            Issue.record("a change on a volume that does not answer was not refused")
            return
        }
        #expect(
            (error as NSError).domain == NSPOSIXErrorDomain && (error as NSError).code == Int(ETIMEDOUT)
                && dead.asked == asked
        )
        // Another volume is none of its business.
        try local.createDirectory(at: box.url("here/new"), cancellation: CancellationFlag())
        #expect(box.exists("here/new"))
        dead.answer()
        #expect(waitUntil { RemoteChanges.shared.strandedCalls(on: dead.root) == 0 })
        // Nothing that was left behind made its folder; a new call does.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dead.root).isEmpty)
        try local.createDirectory(at: box.url("share/more"), cancellation: CancellationFlag())
        #expect(box.exists("share/more"))
    }

    @Test
    internal func aChangeThatComesBackInTimeIsNotLeftBehind() throws {
        let box = try Sandbox()
        let dead = DeadVolume(try box.folder("share"))
        try box.file("share/a.txt", "a")
        // Patience enough for the "server" to answer after the flag was set.
        let local = dead.fileSystem(patienceAfterCancel: 60)
        let flag = CancellationFlag()
        let moving = Running {
            try local.move(box.url("share/a.txt"), to: box.url("share/b.txt"), replacing: false, cancellation: flag)
        }
        #expect(waitUntil { dead.waiting == 1 })
        flag.cancel()
        dead.answer()
        // It came back, saw the flag before its next step, and says so: nothing was renamed.
        #expect(wasCancelled(moving.wait()))
        #expect(
            RemoteChanges.shared.strandedCalls(on: dead.root) == 0 && box.exists("share/a.txt")
                && !box.exists("share/b.txt")
        )
    }

    @Test
    internal func aCopyOntoAVolumeThatDoesNotAnswerLeavesNothingAndReportsToNobodyAfterItWasLeft() throws {
        let box = try Sandbox()
        let dead = DeadVolume(try box.folder("share"))
        try box.file("here/a.txt", "abc")
        let local = dead.fileSystem()
        let flag = CancellationFlag()
        let reports = Locked(0)
        let copying = Running {
            try local.copy(box.url("here/a.txt"), to: box.url("share/a.txt"), cancellation: flag) { _ in
                reports.withValue { $0 += 1 }
                return true
            }
        }
        #expect(waitUntil { dead.waiting == 1 })
        flag.cancel()
        #expect(wasCancelled(copying.wait()))
        dead.answer()
        #expect(waitUntil { RemoteChanges.shared.strandedCalls(on: dead.root) == 0 })
        #expect(!box.exists("share/a.txt") && reports.withValue { $0 } == 0 && box.read("here/a.txt") == "abc")
    }

    @Test
    internal func theVolumeIsAskedOnceAndAnsweredFromMemoryWhileItIsSilent() async throws {
        let box = try Sandbox()
        let dead = DeadVolume(try box.folder("share"))
        try box.file("share/a.txt")
        let local = dead.fileSystem(volumePatience: 0.2)
        // With a flag: the wait ends with the flag, at once.
        let flag = CancellationFlag()
        let first = Running { local.volume(of: box.url("share/a.txt"), cancellation: flag) }
        #expect(waitUntil { dead.waiting == 1 })
        flag.cancel()
        guard case .success(let none)? = first.wait() else {
            Issue.record("the question about the volume did not end with its flag")
            return
        }
        #expect(none == nil)
        // However many ask now, with flags or without: the one question that is under way
        // is the only one, and after the moment a volume is given everybody is answered
        // from what is known (here: only the name of its folder).
        let askers = (0..<20)
            .map { index in
                Running {
                    index % 2 == 0
                        ? local.volume(of: box.url("share"))
                        : local.volume(of: box.url("share/x/y"), cancellation: CancellationFlag())
                }
            }
        for asker in askers {
            guard case .success(let info)? = asker.wait() else {
                Issue.record("a question about a silent volume did not come back")
                continue
            }
            #expect(info?.name == "share" && info?.isLocal == false && info?.freeBytes == nil)
        }
        #expect(dead.asked == 1 && dead.waiting == 1)
        // Other volumes answer meanwhile.
        // (Asked until the answer is in: the moment this test gives a volume is short, and a
        // busy disk may take longer, which is then answered from memory like any other.)
        #expect(waitUntil { local.volume(of: box.root, cancellation: CancellationFlag())?.totalBytes != nil })

        // The server is back: whoever was given the old figures is told to ask again.
        final class Heard: @unchecked Sendable {
            let lock = NSLock()
            var roots: [String] = []
        }
        let heard = Heard()
        let observer = NotificationCenter.default.addObserver(
            forName: FileSystemRegistry.volumeInfoDidChange,
            object: local,
            queue: nil
        ) { note in
            guard let root = note.userInfo?[FileSystemRegistry.volumeRootKey] as? URL else {
                return
            }
            heard.lock.lock()
            heard.roots.append(root.path)
            heard.lock.unlock()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        dead.answer()
        func wasHeard() -> Bool {
            heard.lock.lock()
            defer { heard.lock.unlock() }
            return heard.roots.contains(dead.root)
        }
        let patience = Date(timeIntervalSinceNow: Wait.ceiling)
        while !wasHeard(), Date() < patience { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(wasHeard())
        #expect(
            waitUntil {
                let fresh = local.volume(of: box.url("share/a.txt"), cancellation: CancellationFlag())
                return fresh?.totalBytes != nil && fresh?.freeBytes != nil
            }
        )
    }

    /// K004 / K007 / K040 end to end, as far as a stand-in can show it: a panel that is
    /// pointed at a dead share again and again costs one thread per question, the caller
    /// leaves with its flag, and the folders on healthy disks load meanwhile.
    @Test
    internal func aFolderOnADeadShareIsTriedAgainAndAgainWithoutCostingAThreadEachTime() throws {
        let box = try Sandbox()
        let dead = DeadVolume(try box.folder("share"))
        try box.file("share/sub/a.txt")
        try box.file("here/b.txt")
        let local = dead.fileSystem(volumePatience: 0.1)
        let fileSystems = FileSystemRegistry()
        fileSystems.register(local)
        let location = box.url("share/sub")
        // What a panel does when it is refreshed: the reading before is given up, a new one begins.
        for round in 0..<40 {
            let flag = CancellationFlag()
            let load = Running { () -> [String] in
                var names: [String] = []
                try PanelLoader.stream(location, showHidden: true, fileSystems: fileSystems, cancellation: flag) {
                    batch in
                    names += batch.listing.items.map(\.name)
                    return true
                }
                return names
            }
            if round == 0 {
                // The first reader gets past the volume (answered from memory after the moment
                // a volume is given) and then waits in the listing: two questions are stuck.
                #expect(waitUntil { dead.waiting == 2 })
            } else {
                usleep(1_000)
            }
            flag.cancel()
            guard case .success(let names)? = load.wait() else {
                Issue.record("a reader of a dead share did not end with its flag, or threw")
                continue
            }
            #expect(names.isEmpty)
        }
        // Forty tries, and what is stuck is what the first one left: the question about the
        // volume and one listing. Nothing was begun behind the listing that was given up.
        #expect(dead.waiting == 2 && dead.asked == 2)
        // A folder on a disk that answers is read meanwhile, by the same file system.
        let healthy = try PanelLoader.load(
            box.url("here"),
            showHidden: true,
            fileSystems: fileSystems,
            cancellation: CancellationFlag()
        )
        #expect(healthy.listing.items.map(\.name) == ["b.txt"] && healthy.listing.volume != nil)
        #expect(waitUntil { local.volume(of: box.url("here"), cancellation: CancellationFlag())?.totalBytes != nil })
        // The server is back: the stuck questions return, and the folder loads.
        dead.answer()
        #expect(waitUntil { dead.waiting == 0 })
        let back = try PanelLoader.load(
            location,
            showHidden: true,
            fileSystems: fileSystems,
            cancellation: CancellationFlag()
        )
        #expect(back.listing.items.map(\.name) == ["a.txt"])
    }
}
