import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import LocalFileSystemPlugin

/// Review 2, local file system: special files, writing new files, and links.
@Suite
internal struct Review2LocalFileSystem {
    /// The file system under test.
    internal let local = LocalFileSystem()

    // MARK: Special files

    /// Runs `body` on a thread of its own and waits for it for a long time; false when it does not
    /// come back (a call that blocks must fail the test, not hang the run).
    private func finishes(_ body: @escaping @Sendable () -> Void) -> Bool {
        OtherThread.result(of: body) != nil
    }

    /// A named pipe called `pipe` in `box`.
    private func fifo(_ box: Sandbox) -> URL {
        let url = box.url("pipe")
        #expect(mkfifo(url.path, 0o600) == 0)
        return url
    }

    /// Reading a pipe, a link to one, a device or a folder fails at once instead of waiting;
    /// a plain file is still read.
    @Test
    internal func readingAPipeOrADeviceIsRefusedAtOnce() throws {
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
        #expect(results.values.allSatisfy(\.self) && results.count == 5)
        // A plain file is still read.
        let file = try box.file("plain.txt", "hello")
        let reader = try local.read(file)
        defer { reader.close() }
        #expect(try reader.read(upToCount: 100) == Data("hello".utf8) && (try reader.read(upToCount: 100)) == nil)
    }

    /// Continuing a pipe or anything through a link fails at once and changes nothing; the file
    /// itself is continued and cut at the offset.
    @Test
    internal func appendingToAPipeIsRefusedAtOnceAndALinkIsNotFollowed() throws {
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
        #expect(threw.count == 3 && threw.allSatisfy(\.self))
        #expect(box.read("target.txt") == "0123456789")
        // Through the name of the file itself it works, and cuts at the offset.
        let writer = try local.append(to: target, at: 4, cancellation: CancellationFlag())
        try writer.write(Data("ab".utf8))
        try writer.close(attributes: FileAttributes())
        #expect(box.read("target.txt") == "0123ab")
    }

    /// Metadata is not copied to or from a pipe, and a copy takes files and links but neither a
    /// folder nor a pipe.
    @Test
    internal func copyingMetadataToOrFromAPipeIsRefusedAndCopyTakesOnlyFilesAndLinks() throws {
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

    /// A read that waits on an empty pipe is ended by `interrupt()`, and no call is begun after it.
    @Test
    internal func aBlockedCallIsEndedByInterrupt() throws {
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

    /// A reader and a writer refuse to go on once interrupted and close cleanly, more than once;
    /// with the flag set nothing is opened or made.
    @Test
    internal func aReaderAndAWriterThatWereInterruptedThrowAndCloseCleanly() throws {
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

    /// A new file is readable by its owner alone until it is closed, and then gets the rights it
    /// was given or the usual ones.
    @Test
    internal func aNewFileIsPrivateUntilItIsClosedAndThenGetsItsRights() throws {
        let box = try Sandbox()
        let url = box.url("new.bin")
        let writer = try local.write(url)
        try writer.write(Data("secret".utf8))
        #expect(url.itemStatus.st_mode & 0o777 == 0o600)
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try writer.close(attributes: FileAttributes(modified: date, permissions: 0o640))
        #expect(url.itemStatus.st_mode & 0o777 == 0o640 && local.item(at: url)?.modified == date)
        // Without rights given, the file gets the usual ones (0644 less the umask).
        let other = box.url("other.bin")
        let second = try local.write(other)
        try second.close(attributes: FileAttributes())
        let mask = umask(0o022)
        umask(mask)
        #expect(other.itemStatus.st_mode & 0o777 == 0o644 & ~mask)
        // A source that was 0600 stays 0600 from the first byte to the last.
        let private600 = box.url("private.bin")
        let third = try local.write(private600)
        try third.close(attributes: FileAttributes(permissions: 0o600))
        #expect(private600.itemStatus.st_mode & 0o777 == 0o600)
        #expect(throws: FileSystemError.self) { try local.write(url) }
    }

    /// The date and rights of a new file go to the file that was written, not to what a link put
    /// in its name points to.
    @Test
    internal func theAttributesOfANewFileGoToTheFileAndNotToWhatTheNameBecame() throws {
        let box = try Sandbox()
        let victim = try box.file("victim.txt", "mine")
        chmod(victim.path, 0o644)
        let before = victim.itemStatus
        let url = box.url("temp.bin")
        let writer = try local.write(url)
        try writer.write(Data("x".utf8))
        // The name is swapped for a link to another file of the user before the file is closed.
        unlink(url.path)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: victim)
        try writer.close(
            attributes: FileAttributes(modified: Date(timeIntervalSince1970: 1_000_000_000), permissions: 0o600)
        )
        let after = victim.itemStatus
        #expect(after.st_mode == before.st_mode && after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec)
        #expect(box.read("victim.txt") == "mine")
    }

    // MARK: Links

    /// Setting the date and rights of a link changes the link, and leaves the file it points to
    /// alone.
    @Test
    internal func settingAttributesOnALinkChangesTheLinkAndNotItsTarget() throws {
        let box = try Sandbox()
        let target = try box.file("target.txt", "t")
        chmod(target.path, 0o644)
        let old = Date(timeIntervalSince1970: 1_500_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: target.path)
        let link = box.url("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try local.setAttributes(FileAttributes(modified: date, permissions: 0o600), of: link)
        let targetStatus = target.itemStatus
        #expect(targetStatus.st_mode & 0o7777 == 0o644 && local.item(at: target)?.modified == old)
        #expect(link.itemStatus.st_mtimespec.tv_sec == 1_700_000_000)
        // A plain file is changed as ever.
        try local.setAttributes(FileAttributes(modified: date, permissions: 0o600), of: target)
        #expect(target.itemStatus.st_mode & 0o7777 == 0o600 && local.item(at: target)?.modified == date)
        #expect(throws: (any Error).self) {
            try local.setAttributes(FileAttributes(permissions: 0o600), of: box.url("missing"))
        }
    }

    /// Dangling links, links to a pipe and links to a folder are listed without waiting, each for
    /// what it leads to.
    @Test
    internal func aLinkIntoNowhereAndALinkToAPipeAreListedWithoutBlocking() throws {
        let box = try Sandbox()
        let pipe = fifo(box)
        try FileManager.default.createSymbolicLink(at: box.url("dangling"), withDestinationURL: box.url("nowhere"))
        try FileManager.default.createSymbolicLink(at: box.url("topipe"), withDestinationURL: pipe)
        try box.folder("dir")
        try FileManager.default.createSymbolicLink(at: box.url("todir"), withDestinationURL: box.url("dir"))
        try FileManager.default.createSymbolicLink(
            at: box.url("rel"),
            withDestinationURL: try #require(URL(string: "dir/../dir"))
        )
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
}
