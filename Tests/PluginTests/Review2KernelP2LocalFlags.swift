import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import LocalFileSystemPlugin

/// Review 2, second pass (L023): the changing calls with a cancellation flag, on a disk of this Mac.
@Suite
internal struct Review2KernelP2LocalFlags {
    /// The local disks with the system's own probes, as the program uses them.
    internal let local = LocalFileSystem()

    /// Every changing call does with a flag that is not set what it does without one, failures included.
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
        let changed = box.url("made/c.txt")
        try local.setAttributes(FileAttributes(modified: date, permissions: 0o640), of: changed, cancellation: flag)
        let item = try #require(local.item(at: changed))
        #expect(item.modified == date && item.permissions == 0o640)
        let mark = Data("0081;65f0a1b2;Safari;".utf8)
        try local.setQuarantine(mark, of: changed, cancellation: flag)
        #expect(local.quarantine(of: changed) == mark)
        try box.file("made/d.txt", "d")
        let tag = Data("red".utf8)
        #expect(tag.withUnsafeBytes { setxattr(changed.path, "afm.test.tag", $0.baseAddress, $0.count, 0, 0) } == 0)
        try local.copyMetadata(from: changed, to: box.url("made/d.txt"), cancellation: flag)
        var carried = [UInt8](repeating: 0, count: 16)
        let length = getxattr(box.url("made/d.txt").path, "afm.test.tag", &carried, carried.count, 0, 0)
        #expect(length == 3 && Data(carried.prefix(3)) == tag)
        var reported: [Int64] = []
        try local.copy(changed, to: box.url("made/e.txt"), cancellation: flag) { bytes in
            reported.append(bytes)
            return true
        }
        #expect(box.read("made/e.txt") == "abc" && local.item(at: box.url("made/e.txt"))?.modified == date)
        #expect(throws: FileSystemError.self) {
            try local.copy(changed, to: box.url("made/e.txt"), cancellation: flag) { _ in true }
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

    /// A flag that is set keeps every change from being begun, and nothing is touched.
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

    /// A lock taken off a file for a change is put back when the change is stopped between its steps.
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
        var info = stat()
        #expect(lstat(file.path, &info) == 0 && info.st_flags & UInt32(UF_IMMUTABLE) != 0)
        #expect(
            Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
                != Date(timeIntervalSince1970: 1_000_000)
        )
    }

    /// A copy is stopped between the steps the system reports, leaving nothing, or is done at once by a clone.
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
