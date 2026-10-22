import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import LocalFileSystemPlugin

extension LocalFileSystem {
    /// `places()` once the first read in the background has landed (it never waits itself).
    func settledPlaces(timeout: TimeInterval = Wait.ceiling) -> [Place] {
        let end = Date().addingTimeInterval(timeout)
        var places = self.places()
        while !places.contains(where: { $0.url.path == "/" }), Date() < end {
            Thread.sleep(forTimeInterval: 0.02)
            places = self.places()
        }
        return places
    }
}

/// Runs `body` on a thread of its own and waits for it for a long time; false when it does not
/// come back (a call that blocks must fail the test, not hang the run).
private func finishes(within seconds: TimeInterval = Wait.ceiling, _ body: @escaping @Sendable () -> Void) -> Bool {
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        body()
        done.signal()
    }
    return done.wait(timeout: .now() + seconds) == .success
}

private func status(_ url: URL) -> stat {
    var st = stat()
    lstat(url.path, &st)
    return st
}

/// Review 2, local file system: special files, links, permissions, locks, places, watching.
@Suite struct Review2LocalFileSystem {
    let local = LocalFileSystem()

    // MARK: Special files

    private func fifo(_ box: Sandbox, _ name: String = "pipe") -> URL {
        let url = box.url(name)
        #expect(mkfifo(url.path, 0o600) == 0)
        return url
    }

    @Test func readingAPipeOrADeviceIsRefusedAtOnce() throws {
        let box = try Sandbox()
        let pipe = fifo(box)
        try FileManager.default.createSymbolicLink(at: box.url("link"), withDestinationURL: pipe)
        // Guarded by `lock`.
        nonisolated(unsafe) var results: [String: Bool] = [:]
        let lock = NSLock()
        for (name, url) in [
            ("pipe", pipe), ("link", box.url("link")), ("null", URL(fileURLWithPath: "/dev/null")),
            ("zero", URL(fileURLWithPath: "/dev/zero")), ("folder", box.root)
        ] {
            let returned = finishes {
                let threw = (try? local.read(url)) == nil
                lock.lock()
                results[name] = threw
                lock.unlock()
            }
            #expect(returned, "reading \(name) did not return")
        }
        #expect(results.values.allSatisfy { $0 } && results.count == 5)
        // A plain file is still read.
        let file = try box.file("plain.txt", "hello")
        let reader = try local.read(file)
        defer { reader.close() }
        #expect(try reader.read(upToCount: 100) == Data("hello".utf8) && (try reader.read(upToCount: 100)) == nil)
    }

    @Test func appendingToAPipeIsRefusedAtOnceAndALinkIsNotFollowed() throws {
        let box = try Sandbox()
        let pipe = fifo(box)
        try FileManager.default.createSymbolicLink(at: box.url("pipelink"), withDestinationURL: pipe)
        let target = try box.file("target.txt", "0123456789")
        try FileManager.default.createSymbolicLink(at: box.url("filelink"), withDestinationURL: target)
        // Guarded by `lock`.
        nonisolated(unsafe) var threw: [Bool] = []
        let lock = NSLock()
        for url in [pipe, box.url("pipelink"), box.url("filelink")] {
            let returned = finishes {
                let failed = (try? local.append(to: url, at: nil, cancellation: CancellationFlag())) == nil
                lock.lock()
                threw.append(failed)
                lock.unlock()
            }
            #expect(returned)
        }
        #expect(threw.count == 3 && threw.allSatisfy { $0 })
        #expect(box.read("target.txt") == "0123456789")
        // Through the name of the file itself it works, and cuts at the offset.
        let writer = try local.append(to: target, at: 4, cancellation: CancellationFlag())
        try writer.write(Data("ab".utf8))
        try writer.close(attributes: FileAttributes())
        #expect(box.read("target.txt") == "0123ab")
    }

    @Test func copyingMetadataToOrFromAPipeIsRefusedAndCopyTakesOnlyFilesAndLinks() throws {
        let box = try Sandbox()
        let pipe = fifo(box)
        let file = try box.file("f.txt", "data")
        // Written by the other thread before it signals, read here after the wait.
        nonisolated(unsafe) var threw = false
        #expect(finishes { threw = (try? local.copyMetadata(from: file, to: pipe)) == nil })
        #expect(threw)
        #expect(finishes { threw = (try? local.copyMetadata(from: pipe, to: file)) == nil })
        #expect(threw)
        // A folder is a tree: it is not copied here, without progress and without a way to stop.
        try box.file("tree/a.txt")
        var calls = 0
        #expect(throws: (any Error).self) {
            try local.copy(box.url("tree"), to: box.url("tree2")) { _ in
                calls += 1
                return true
            }
        }
        #expect(!box.exists("tree2") && calls == 0)
        #expect(throws: (any Error).self) { try local.copy(pipe, to: box.url("pipe2")) { _ in true } }
        // A link is copied as a link.
        try FileManager.default.createSymbolicLink(at: box.url("ln"), withDestinationURL: file)
        try local.copy(box.url("ln"), to: box.url("ln2")) { _ in true }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: box.url("ln2").path) == file.path)
    }

    @Test func aBlockedCallIsEndedByInterrupt() throws {
        // Not 0: should the pipe not be made, nothing is closed that is somebody else's.
        var pair: [Int32] = [-1, -1]
        try #require(pipe(&pair) == 0)
        defer {
            close(pair[0])
            close(pair[1])
        }
        let interruption = Interruption()
        let outcome = Locked<String>("waiting")
        let started = DispatchSemaphore(value: 0)
        let readEnd = pair[0]
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            started.signal()
            do {
                var byte: UInt8 = 0
                _ = try interruption.run { Darwin.read(readEnd, &byte, 1) }
                outcome.withValue { $0 = "read" }
            } catch {
                outcome.withValue { $0 = "interrupted" }
            }
            done.signal()
        }
        started.wait()
        Thread.sleep(forTimeInterval: 0.2)
        interruption.interrupt()
        // The thread comes back (it was blocked in the pipe, which nobody writes to).
        let returned = done.wait(timeout: .now() + Wait.ceiling) == .success
        #expect(returned)
        #expect(outcome.withValue { $0 } == "interrupted")
        #expect(throws: (any Error).self) { try interruption.run { 0 } }
    }

    @Test func aReaderAndAWriterThatWereInterruptedThrowAndCloseCleanly() throws {
        let box = try Sandbox()
        let file = try box.file("f.txt", String(repeating: "z", count: 100))
        let reader = try local.read(file)
        #expect(try reader.read(upToCount: 10)?.count == 10)
        try reader.seek(to: 95)
        #expect(try reader.read(upToCount: 10)?.count == 5)
        reader.interrupt()
        reader.interrupt()
        #expect(throws: (any Error).self) { try reader.read(upToCount: 10) }
        reader.close()
        reader.close()
        let writer = try local.write(box.url("out.bin"))
        try writer.write(Data("abc".utf8))
        writer.interrupt()
        #expect(throws: (any Error).self) { try writer.write(Data("def".utf8)) }
        try writer.close(attributes: FileAttributes())
        #expect(box.read("out.bin") == "abc")
        let flag = CancellationFlag()
        flag.cancel()
        #expect(throws: (any Error).self) { try local.read(file, cancellation: flag) }
        #expect(throws: (any Error).self) { try local.write(box.url("never.bin"), cancellation: flag) }
        #expect(!box.exists("never.bin"))
    }

    // MARK: write()

    @Test func aNewFileIsPrivateUntilItIsClosedAndThenGetsItsRights() throws {
        let box = try Sandbox()
        let url = box.url("new.bin")
        let writer = try local.write(url)
        try writer.write(Data("secret".utf8))
        #expect(status(url).st_mode & 0o777 == 0o600)
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try writer.close(attributes: FileAttributes(modified: date, permissions: 0o640))
        #expect(status(url).st_mode & 0o777 == 0o640 && local.item(at: url)?.modified == date)
        // Without rights given, the file gets the usual ones (0644 less the umask).
        let other = box.url("other.bin")
        let second = try local.write(other)
        try second.close(attributes: FileAttributes())
        let mask = umask(0o022)
        umask(mask)
        #expect(status(other).st_mode & 0o777 == 0o644 & ~mask)
        // A source that was 0600 stays 0600 from the first byte to the last.
        let private600 = box.url("private.bin")
        let third = try local.write(private600)
        try third.close(attributes: FileAttributes(permissions: 0o600))
        #expect(status(private600).st_mode & 0o777 == 0o600)
        #expect(throws: FileSystemError.self) { try local.write(url) }
    }

    @Test func theAttributesOfANewFileGoToTheFileAndNotToWhatTheNameBecame() throws {
        let box = try Sandbox()
        let victim = try box.file("victim.txt", "mine")
        chmod(victim.path, 0o644)
        let before = status(victim)
        let url = box.url("temp.bin")
        let writer = try local.write(url)
        try writer.write(Data("x".utf8))
        // The name is swapped for a link to another file of the user before the file is closed.
        unlink(url.path)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: victim)
        try writer.close(
            attributes: FileAttributes(modified: Date(timeIntervalSince1970: 1_000_000_000), permissions: 0o600)
        )
        let after = status(victim)
        #expect(after.st_mode == before.st_mode && after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec)
        #expect(box.read("victim.txt") == "mine")
    }

    // MARK: Links

    @Test func settingAttributesOnALinkChangesTheLinkAndNotItsTarget() throws {
        let box = try Sandbox()
        let target = try box.file("target.txt", "t")
        chmod(target.path, 0o644)
        let old = Date(timeIntervalSince1970: 1_500_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: target.path)
        let link = box.url("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try local.setAttributes(FileAttributes(modified: date, permissions: 0o600), of: link)
        let st = status(target)
        #expect(st.st_mode & 0o7777 == 0o644 && local.item(at: target)?.modified == old)
        #expect(status(link).st_mtimespec.tv_sec == 1_700_000_000)
        // A plain file is changed as ever.
        try local.setAttributes(FileAttributes(modified: date, permissions: 0o600), of: target)
        #expect(status(target).st_mode & 0o7777 == 0o600 && local.item(at: target)?.modified == date)
        #expect(throws: (any Error).self) {
            try local.setAttributes(FileAttributes(permissions: 0o600), of: box.url("missing"))
        }
    }

    @Test func aLinkIntoNowhereAndALinkToAPipeAreListedWithoutBlocking() throws {
        let box = try Sandbox()
        let pipe = fifo(box)
        try FileManager.default.createSymbolicLink(at: box.url("dangling"), withDestinationURL: box.url("nowhere"))
        try FileManager.default.createSymbolicLink(at: box.url("topipe"), withDestinationURL: pipe)
        try box.folder("dir")
        try FileManager.default.createSymbolicLink(at: box.url("todir"), withDestinationURL: box.url("dir"))
        try FileManager.default.createSymbolicLink(at: box.url("rel"), withDestinationURL: URL(string: "dir/../dir")!)
        // Used by the work on its own thread only while the test waits for it to finish.
        nonisolated(unsafe) var items: [FileItem] = []
        #expect(finishes { items = (try? local.list(box.root, showHidden: true)) ?? [] })
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        #expect(byName["dangling"]?.isSymlink == true && byName["dangling"]?.isDirectory == false)
        #expect(byName["topipe"]?.isSpecial == true && byName["pipe"]?.isSpecial == true)
        #expect(byName["todir"]?.isDirectory == true && byName["rel"]?.isDirectory == true)
        // The single item agrees.
        #expect(
            local.item(at: box.url("todir"))?.isDirectory == true
                && local.item(at: box.url("topipe"))?.isSpecial == true
        )
    }

    // MARK: Locks

    private func lock(_ url: URL) { chflags(url.path, UInt32(UF_IMMUTABLE)) }
    private func unlockAll(in box: Sandbox) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: box.root.path) else {
            return
        }
        for name in names { lchflags(box.url(name).path, 0) }
    }

    @Test func aLockedCopyThatKeptItsNameIsAsLockedAsItsSource() throws {
        let box = try Sandbox()
        defer { unlockAll(in: box) }
        let source = try box.file("src.txt", "data")
        lock(source)
        try local.copy(source, to: box.url("dst.txt")) { _ in true }
        #expect(status(box.url("dst.txt")).st_flags & UInt32(UF_IMMUTABLE) != 0)
        // Not unlocked and deleted merely because it was copied by this file system.
        #expect(throws: (any Error).self) { try local.remove(box.url("dst.txt")) }
        #expect(throws: (any Error).self) {
            try local.move(box.url("dst.txt"), to: box.url("moved.txt"), replacing: false)
        }
        #expect(box.exists("dst.txt"))
        // A locked folder whose metadata was copied is the user's as well.
        let folder = try box.folder("srcdir")
        let copy = try box.folder("copydir")
        lock(folder)
        try local.copyMetadata(from: folder, to: copy)
        #expect(status(copy).st_flags & UInt32(UF_IMMUTABLE) != 0)
        #expect(throws: (any Error).self) { try local.remove(copy) }
        #expect(box.exists("copydir"))
    }

    @Test func aLockedCopyUnderATemporaryNameCanBeGivenItsRealName() throws {
        let box = try Sandbox()
        defer { unlockAll(in: box) }
        let source = try box.file("src.txt", "data")
        lock(source)
        let temporary = box.url(".afm-\(UUID().uuidString).tmp")
        try local.copy(source, to: temporary) { _ in true }
        try local.move(temporary, to: box.url("final.txt"), replacing: false)
        #expect(status(box.url("final.txt")).st_flags & UInt32(UF_IMMUTABLE) != 0)
        // The entry went with the rename: the file with its real name is refused now.
        #expect(throws: (any Error).self) { try local.remove(box.url("final.txt")) }
        // A temporary that is abandoned can be removed.
        let abandoned = box.url(".afm-\(UUID().uuidString).tmp")
        try local.copy(source, to: abandoned) { _ in true }
        try local.remove(abandoned)
        #expect(!box.exists(abandoned.lastPathComponent))
    }

    @Test func theTableOfLockedTemporariesIsNeverWipedWholesale() throws {
        let box = try Sandbox()
        defer { unlockAll(in: box) }
        let source = try box.file("src.txt", "d")
        lock(source)
        let count = 4_096 + 40
        for number in 0..<count { try local.copy(source, to: box.url(".afm-\(number).tmp")) { _ in true } }
        // The recent ones are all still this file system's to rename (a wipe at 4,096 drops them).
        for number in (count - 30)..<count {
            try local.move(box.url(".afm-\(number).tmp"), to: box.url("done-\(number).txt"), replacing: false)
        }
        #expect(box.exists("done-\(count - 1).txt"))
    }

    // MARK: Moving

    @Test func movingOntoAnotherNameOfTheSameFileMovesIt() throws {
        let box = try Sandbox()
        let a = try box.file("a.txt", "same")
        let b = box.url("b.txt")
        try FileManager.default.linkItem(at: a, to: b)
        try local.move(a, to: b, replacing: true)
        #expect(!box.exists("a.txt") && box.read("b.txt") == "same")
        // A change of the letters' case is a rename and loses nothing.
        let upper = try box.file("Case.txt", "c")
        try local.move(upper, to: box.url("case.txt"), replacing: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: box.root.path).sorted()
        #expect(names == ["b.txt", "case.txt"] && box.read("case.txt") == "c")
    }

    @Test func aRenameOfOnlyTheLettersCaseOrTheFormOfAnAccentNeverRemovesTheFile() throws {
        let box = try Sandbox()
        let decomposed = "e\u{0301}.txt"
        let composed = "\u{00E9}.txt"
        // Replacing or not, accent to accent and case to case: the file is there afterwards, once.
        for replacing in [true, false] {
            let from = try box.file(replacing ? decomposed : "x" + decomposed, "accent")
            let to = box.url(replacing ? composed : "x" + composed)
            try local.move(from, to: to, replacing: replacing)
            let names = try FileManager.default.contentsOfDirectory(atPath: box.root.path)
            #expect(names.count == 1, "\(names)")
            #expect(try String(contentsOf: to, encoding: .utf8) == "accent")
            // And back the other way.
            try local.move(to, to: from, replacing: replacing)
            #expect(try String(contentsOf: from, encoding: .utf8) == "accent")
            try FileManager.default.removeItem(at: from)
        }
        for replacing in [true, false] {
            let from = try box.file("Mixed.txt", "case")
            try local.move(from, to: box.url("MIXED.txt"), replacing: replacing)
            #expect(try FileManager.default.contentsOfDirectory(atPath: box.root.path) == ["MIXED.txt"])
            #expect(box.read("mixed.txt") == "case")
            try FileManager.default.removeItem(at: box.url("MIXED.txt"))
        }
        // Two hard links in different folders: the move still moves.
        let a = try box.file("one/a.txt", "linked")
        try box.folder("two")
        try FileManager.default.linkItem(at: a, to: box.url("two/b.txt"))
        try local.move(a, to: box.url("two/b.txt"), replacing: true)
        #expect(!box.exists("one/a.txt") && box.read("two/b.txt") == "linked")
    }

    // MARK: Places and volumes

    @Test func thePlacesAreAnsweredAtOnceAndAnnouncedWhenTheyChange() async throws {
        let fresh = LocalFileSystem()
        let start = DispatchTime.now().uptimeNanoseconds
        let first = fresh.places()
        for _ in 0..<1_000 { _ = fresh.places() }
        // No call waits for the first reading (it used to wait a second at a time).
        #expect(DispatchTime.now().uptimeNanoseconds - start < 800_000_000)
        #expect(first.first?.kind == .home)
        let settled = fresh.settledPlaces()
        #expect(settled.contains { $0.url.path == "/" && $0.kind == .internalDisk })
        // The read list was announced on the main thread: it differs from the fixed places.
        // Listened for before the file system exists: it begins to read the moment it is
        // made, and may have told the world before a listener that came after it was there.
        let heard = Locked<[(ObjectIdentifier, Bool)]>([])
        let observer = NotificationCenter.default.addObserver(
            forName: LocalFileSystem.placesDidChange,
            object: nil,
            queue: nil
        ) { note in
            guard let sender = note.object as AnyObject? else {
                return
            }
            heard.withValue { $0.append((ObjectIdentifier(sender), Thread.isMainThread)) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let again = LocalFileSystem()
        let own = ObjectIdentifier(again)
        func announcements() -> [Bool] { heard.withValue { $0.filter { $0.0 == own }.map(\.1) } }
        let patience = Date(timeIntervalSinceNow: Wait.ceiling)
        while announcements().isEmpty, Date() < patience { try await Task.sleep(nanoseconds: 10_000_000) }
        // On the main thread, and at least once: other tests of the run attach and detach disk
        // images meanwhile, and each of those is a change of the places that is announced too
        // (seen once in a full run as two announcements where this expected exactly one).
        let told = announcements()
        #expect(!told.isEmpty && told.allSatisfy { $0 }, "\(told)")
        withExtendedLifetime(again) {}
    }

    @Test func askingForVolumesOftenIsQuickAndAgrees() throws {
        let box = try Sandbox()
        let first = try #require(local.volume(of: box.root))
        let done = Locked(0)
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            if local.volume(of: box.url("not/there/yet.txt"))?.name == first.name { done.withValue { $0 += 1 } }
        }
        #expect(done.withValue { $0 } == 200)
    }
}

/// The watcher: no waiting for the caller, one report for a burst, nothing after stop.
@Suite struct Review2DirectoryWatcher {
    @Test func startingToWatchReturnsAtOnceEvenForManyFolders() throws {
        let box = try Sandbox()
        let folders = (0..<500).map { box.url("f\($0)") }
        let watcher = DirectoryWatcher(queue: DispatchQueue(label: "test")) { _ in }
        let start = DispatchTime.now().uptimeNanoseconds
        watcher.watch(folders)
        watcher.watch(Array(folders.prefix(3)))
        // Two calls that only note what is wanted; the stream is made behind them.
        #expect(DispatchTime.now().uptimeNanoseconds - start < 500_000_000)
        watcher.stop()
    }

    @Test func aBurstOfChangesIsReportedInLumpsAndNothingComesAfterStop() async throws {
        let box = try Sandbox()
        try box.folder("watched")
        let count = Locked(0)
        let watcher = DirectoryWatcher(queue: DispatchQueue(label: "test")) { _ in count.withValue { $0 += 1 } }
        watcher.watch([box.url("watched")])
        let started = Date()
        var number = 0
        // A flood for a few seconds; the first report cannot come before the stream runs.
        while Date().timeIntervalSince(started) < 4 || count.withValue({ $0 }) == 0 {
            try box.file("watched/f\(number).txt")
            if number > 3 { try? FileManager.default.removeItem(at: box.url("watched/f\(number - 3).txt")) }
            number += 1
            if number % 20 == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
            // Given up by the count as well as by the clock: a pause here has taken minutes
            // among the other tests, and the changes made before it may all have come before
            // the stream ran (see the next test).
            if Date().timeIntervalSince(started) > 60, number > 2_000 { break }
        }
        let elapsed = Date().timeIntervalSince(started)
        let reports = count.withValue { $0 }
        // Hundreds of changes; at most one report per half second (plus slack).
        #expect(
            reports >= 1 && Double(reports) <= elapsed / 0.5 + 3,
            "\(reports) reports in \(elapsed) s for \(number) changes"
        )
        watcher.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        let afterStop = count.withValue { $0 }
        for index in 0..<20 { try box.file("watched/late\(index).txt") }
        try await Task.sleep(nanoseconds: 1_800_000_000)
        #expect(count.withValue { $0 } == afterStop)
    }

    @Test func aFolderThatIsWatchedAgainAfterAChangeOfTheSetKeepsReporting() async throws {
        let box = try Sandbox()
        try box.folder("a")
        try box.folder("b")
        let seen = Locked(Set<String>())
        let watcher = DirectoryWatcher(queue: DispatchQueue(label: "test")) { urls in
            seen.withValue { $0.formUnion(urls.map(\.lastPathComponent)) }
        }
        watcher.watch([box.url("a")])
        watcher.watch([box.url("a"), box.url("b")])
        // A change is made again and again until one is reported. The first ones may come
        // before the stream for the new set runs, and what was changed more than a moment
        // before a stream starts is not reported to it (measured: 18 of 20 at 2 ms, 0 of 20
        // at 50 ms). So the test must get to make further changes, and that is counted, not
        // timed: among the other tests of the process a pause of 0.2 s has taken more than
        // two minutes (every thread the tests share was held by tests that wait), and a loop
        // bounded by the clock alone then ended after its first round, with "no report in
        // 60 s" for a watcher that had not been given a change it could see. That, not the
        // watcher, was the failure once seen in a full run.
        var number = 0
        let started = Date()
        while !seen.withValue({ $0.contains("b") }), number < 50 || Date().timeIntervalSince(started) < 60,
            number < 3_000
        {
            try box.file("b/f\(number).txt")
            number += 1
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        #expect(
            seen.withValue { $0.contains("b") },
            "no report after \(number) changes in \(Int(Date().timeIntervalSince(started))) s"
        )
        watcher.stop()
    }
}
