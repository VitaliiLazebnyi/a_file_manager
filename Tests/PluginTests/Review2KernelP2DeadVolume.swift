import AFMKernel
import Foundation
import TestSupport
import Testing
import os

@testable import LocalFileSystemPlugin

/// A share whose server has gone, stood in for by a folder whose questions do not come back.
@Suite
internal struct Review2KernelP2DeadVolume {
    /// Waits for a condition, not for a length of time; false only after a very long while (`Wait.ceiling`).
    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let end = Date(timeIntervalSinceNow: Wait.ceiling)
        while !condition() {
            if Date() > end {
                return false
            }
            usleep(2_000)
        }
        return true
    }

    /// A change on a volume that does not answer lets its caller go when the flag is set, and makes no further
    /// step when the server answers again.
    @Test
    internal func aChangeOnAVolumeThatDoesNotAnswerIsLeftBehindWhenItsFlagIsSet() throws {
        let box = try Sandbox()
        let dead = DeadVolume(try box.folder("share"))
        try box.file("share/a.txt", "a")
        try box.file("here/b.txt", "b")
        let local = dead.fileSystem(patienceAfterCancel: 0.2, volumePatience: 0.3)
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
        #expect(removal.endsCancelled())
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

    /// A volume with as many calls left behind as allowed is not asked again, until one of them returns.
    @Test
    internal func aVolumeWithSeveralCallsLeftBehindIsNotAskedAgainUntilOneReturns() throws {
        let box = try Sandbox()
        let dead = DeadVolume(try box.folder("share"))
        let local = dead.fileSystem(patienceAfterCancel: 0.05, volumePatience: 0.3)
        for index in 0..<RemoteChanges.limit {
            let flag = CancellationFlag()
            let making = Running { try local.createDirectory(at: box.url("share/new\(index)"), cancellation: flag) }
            #expect(waitUntil { dead.waiting == index + 1 })
            flag.cancel()
            #expect(making.endsCancelled())
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

    /// A change that comes back within its patience after the flag was set is not left behind, and makes no
    /// further step.
    @Test
    internal func aChangeThatComesBackInTimeIsNotLeftBehind() throws {
        let box = try Sandbox()
        let dead = DeadVolume(try box.folder("share"))
        try box.file("share/a.txt", "a")
        // Patience enough for the "server" to answer after the flag was set.
        let local = dead.fileSystem(patienceAfterCancel: 60, volumePatience: 0.3)
        let flag = CancellationFlag()
        let moving = Running {
            try local.move(box.url("share/a.txt"), to: box.url("share/b.txt"), replacing: false, cancellation: flag)
        }
        #expect(waitUntil { dead.waiting == 1 })
        flag.cancel()
        dead.answer()
        // It came back, saw the flag before its next step, and says so: nothing was renamed.
        #expect(moving.endsCancelled())
        #expect(
            RemoteChanges.shared.strandedCalls(on: dead.root) == 0 && box.exists("share/a.txt")
                && !box.exists("share/b.txt")
        )
    }

    /// A copy onto a volume that does not answer leaves no file, and reports no progress after it was left behind.
    @Test
    internal func aCopyOntoAVolumeThatDoesNotAnswerLeavesNothingAndReportsToNobodyAfterItWasLeft() throws {
        let box = try Sandbox()
        let dead = DeadVolume(try box.folder("share"))
        try box.file("here/a.txt", "abc")
        let local = dead.fileSystem(patienceAfterCancel: 0.2, volumePatience: 0.3)
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
        #expect(copying.endsCancelled())
        dead.answer()
        #expect(waitUntil { RemoteChanges.shared.strandedCalls(on: dead.root) == 0 })
        #expect(!box.exists("share/a.txt") && reports.withValue { $0 } == 0 && box.read("here/a.txt") == "abc")
    }

    /// A silent volume is asked once and everybody else is answered from memory, until it answers again and that is
    /// announced.
    @Test
    internal func theVolumeIsAskedOnceAndAnsweredFromMemoryWhileItIsSilent() async throws {
        let box = try Sandbox()
        let dead = DeadVolume(try box.folder("share"))
        try box.file("share/a.txt")
        let local = dead.fileSystem(patienceAfterCancel: 0.2, volumePatience: 0.2)
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
                    index.isMultiple(of: 2)
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
        try await expectTheReturnIsAnnounced(dead, on: local, at: box.url("share/a.txt"))
    }

    /// The server comes back: whoever was given the old figures of the volume is told to ask again, and is then
    /// answered in full.
    private func expectTheReturnIsAnnounced(
        _ dead: DeadVolume,
        on local: LocalFileSystem,
        at location: URL
    ) async throws {
        // The volume roots announced, as paths.
        let heard = OSAllocatedUnfairLock<[String]>(initialState: [])
        let observer = NotificationCenter.default.addObserver(
            forName: FileSystemRegistry.volumeInfoDidChange,
            object: local,
            queue: nil
        ) { note in
            guard let root = note.userInfo?[FileSystemRegistry.volumeRootKey] as? URL else {
                return
            }
            heard.withLock { $0.append(root.path) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        dead.answer()
        func wasHeard() -> Bool {
            heard.withLock { $0.contains(dead.root) }
        }
        let patience = Date(timeIntervalSinceNow: Wait.ceiling)
        while !wasHeard(), Date() < patience { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(wasHeard())
        #expect(
            waitUntil {
                let fresh = local.volume(of: location, cancellation: CancellationFlag())
                return fresh?.totalBytes != nil && fresh?.freeBytes != nil
            }
        )
    }

    /// A panel's reading of `location`, as the panel streams it, on a thread of its own: the names it was given.
    private func reading(
        _ location: URL,
        from fileSystems: FileSystemRegistry,
        cancellation flag: CancellationFlag
    ) -> Running<[String]> {
        Running { () -> [String] in
            var names: [String] = []
            try PanelLoader.stream(location, showHidden: true, fileSystems: fileSystems, cancellation: flag) { batch in
                names += batch.listing.items.map(\.name)
                return true
            }
            return names
        }
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
        let local = dead.fileSystem(patienceAfterCancel: 0.2, volumePatience: 0.1)
        let fileSystems = FileSystemRegistry()
        fileSystems.register(local)
        let location = box.url("share/sub")
        // What a panel does when it is refreshed: the reading before is given up, a new one begins.
        for round in 0..<40 {
            let flag = CancellationFlag()
            let load = reading(location, from: fileSystems, cancellation: flag)
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
