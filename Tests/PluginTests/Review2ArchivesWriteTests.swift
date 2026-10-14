import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Review round 2: nothing that was put into an archive is lost, written twice or written
/// where it does not belong, whatever happens while it is written.
@Suite struct Review2ArchivesWrites {
    let bench: ArchiveBench
    var box: Sandbox { bench.box }

    init() throws {
        bench = try ArchiveBench()
    }

    func makeZip(_ name: String = "tree.zip") throws -> URL {
        try bench.makeTree()
        #expect(runTool("/usr/bin/zip", ["-qr", name, "tree"], in: box.root).status == 0)
        return box.url(name)
    }

    func write(_ text: String, to url: URL) throws {
        let writer = try bench.fileSystems.provider(for: url).write(url)
        try writer.write(Data(text.utf8))
        try writer.close(attributes: FileAttributes())
    }

    func listed(_ archive: URL) -> [String] {
        runTool("/usr/bin/unzip", ["-Z1", archive.path]).output.split(separator: "\n").map(String.init)
    }

    /// Puts a file of the disk onto the memory file system ("a server").
    func upload(_ local: URL, to path: String) throws -> URL {
        let url = bench.memory.url(path)
        bench.memory.createDirectory(at: url.deletingLastPathComponent())
        let writer = try bench.memory.write(url)
        try writer.write(try Data(contentsOf: local))
        try writer.close(attributes: FileAttributes())
        return url
    }

    /// What the server holds, as a file on the disk that the system's tools can look at.
    func download(_ url: URL, as name: String) throws -> URL {
        let local = box.url(name)
        try? FileManager.default.removeItem(at: local)
        try bench.read(url).write(to: local)
        return local
    }

    // MARK: Quit (A011, A012, A027, A086)

    @Test func oneCallWritesAnArchiveInsideAnArchive() throws {
        try bench.makeTree()
        #expect(runTool("/usr/bin/zip", ["-qr", "inner.zip", "tree"], in: box.root).status == 0)
        // Large enough that putting it back into the outer archive is left to the delay.
        #expect(try Data(contentsOf: box.url("inner.zip")).count > 300_000)
        #expect(runTool("/usr/bin/zip", ["-q0", "outer.zip", "inner.zip"], in: box.root).status == 0)
        let inner = bench.inside(box.url("outer.zip"), "inner.zip")
        // Both orders of the store's table: whichever archive comes first, both are written.
        for round in 0..<6 {
            try write("edit \(round)", to: bench.inside(inner, "tree/new\(round).txt"))
            #expect(bench.store.flushAll().isEmpty && !bench.store.hasPendingChanges)
            bench.store.close()
            try? FileManager.default.removeItem(at: box.url("check"))
            #expect(
                runTool("/usr/bin/unzip", ["-qo", box.url("outer.zip").path, "-d", box.url("check").path]).status == 0)
            #expect(listed(box.url("check/inner.zip")).contains("tree/new\(round).txt"), "round \(round)")
        }
    }

    @Test func oneCallWritesAnArchiveOnAServerThatKeepsWritesBack() throws {
        let local = try makeZip()
        let onServer = try upload(local, to: "/store/tree.zip")
        try write("to the server", to: bench.inside(onServer, "tree/sent.txt"))
        #expect(bench.store.flushAll().isEmpty && !bench.store.hasPendingChanges)
        #expect(listed(try download(onServer, as: "from-server.zip")).contains("tree/sent.txt"))
        // Nothing with a temporary name stays on the server.
        #expect(bench.memory.allPaths.allSatisfy { !$0.contains(".afm-") })
    }

    // MARK: Changes while a write is under way (A016, A017)

    @Test func aMemberDeletedWhileItIsFirstWrittenIsGoneAfterTheNextWrite() throws {
        let archive = try makeZip()
        let tree = bench.inside(archive, "tree")
        try write("short-lived", to: tree.appending(name: "new.txt"))
        try write("stays", to: tree.appending(name: "other.txt"))
        // Used by the callbacks, which run one at a time while the calls below wait for them.
        nonisolated(unsafe) var fired = false
        bench.environment.whileWriting = { [bench] in
            guard !fired else { return }
            fired = true
            try? bench.zip.remove(tree.appending(name: "new.txt"))
        }
        // The first write puts the member into the file; the deletion comes while it runs.
        #expect(bench.store.flushAll().isEmpty && fired)
        bench.environment.whileWriting = nil
        #expect(bench.store.flushAll().isEmpty && !bench.store.hasPendingChanges)
        #expect(!listed(archive).contains("tree/new.txt") && listed(archive).contains("tree/other.txt"))
        bench.store.close()
        #expect(try !bench.names(tree).contains("new.txt") && bench.names(tree).contains("other.txt"))
    }

    @Test func aMemberReplacedWhileItIsFirstWrittenIsWrittenOnce() throws {
        let archive = try makeZip()
        let member = bench.inside(archive, "tree/twice.txt")
        try write("first version", to: member)
        // Used by the callbacks, which run one at a time while the calls below wait for them.
        nonisolated(unsafe) var fired = false
        bench.environment.whileWriting = { [bench] in
            guard !fired else { return }
            fired = true
            try? bench.zip.remove(member)
            try? write("second version", to: member)
        }
        #expect(bench.store.flushAll().isEmpty && fired && !bench.store.hasPendingChanges)
        bench.environment.whileWriting = nil
        #expect(listed(archive).filter { $0 == "tree/twice.txt" }.count == 1)
        #expect(runTool("/usr/bin/unzip", ["-p", archive.path, "tree/twice.txt"]).output == "second version")
    }

    // MARK: Members on their way (A033, A101)

    @Test func aMemberUnderAJobsTemporaryNameIsNeverWrittenIntoTheFile() throws {
        let archive = try makeZip()
        let tree = bench.inside(archive, "tree")
        let temporary = tree.appending(name: ".afm-\(UUID().uuidString).tmp")
        #expect(
            OpenArchive.isTransferName(temporary.lastPathComponent) && !OpenArchive.isTransferName(".afm-short.tmp"))
        try write("on its way", to: temporary)
        try write("already there", to: tree.appending(name: "done.txt"))
        let open = try bench.store.archive(at: archive)
        // Written by whoever writes (the delay, a commit, the quit): the member is left out,
        // and it is not counted as a change that waits.
        #expect(bench.store.flushAll().isEmpty && !open.hasPendingChanges)
        #expect(listed(archive).contains("tree/done.txt") && !listed(archive).contains { $0.contains(".afm-") })
        // The archive is not let go while the member is on its way.
        #expect(open.isBusy && !open.retireIfIdle())
        // It joins the file with its real name.
        try bench.zip.move(temporary, to: tree.appending(name: "arrived.txt"), replacing: false)
        #expect(bench.store.flushAll().isEmpty && !open.isBusy)
        #expect(listed(archive).contains("tree/arrived.txt") && !listed(archive).contains { $0.contains(".afm-") })
        // One that its job gives up leaves nothing behind.
        let abandoned = tree.appending(name: ".afm-\(UUID().uuidString).tmp")
        try write("given up", to: abandoned)
        try bench.zip.remove(abandoned)
        #expect(bench.store.flushAll().isEmpty && !open.isBusy && !listed(archive).contains { $0.contains(".afm-") })
    }

    // MARK: Archives the store lets go (A021, A024, A028, A072)

    @Test func aChangeNeverLandsInAnArchiveTheStoreHasLetGo() throws {
        let archive = try makeZip()
        let first = try bench.store.archive(at: archive)
        // With something waiting, or a writer open, the archive is not let go.
        let writer = try bench.zip.write(bench.inside(archive, "tree/held.txt"))
        #expect(!first.retireIfIdle())
        try writer.write(Data("held".utf8))
        try writer.close(attributes: FileAttributes())
        #expect(!first.retireIfIdle() && bench.store.flushAll().isEmpty)
        // Let go when idle (as eviction does), it takes no change any more…
        #expect(first.retireIfIdle() && !first.isCurrent())
        #expect { try first.write("tree/lost.txt") } throws: { error in
            if case ArchiveError.retired = error { return true }
            return false
        }
        #expect(throws: ArchiveError.self) { try first.remove("tree/readme.txt") }
        // …and the change that comes through the file system is made in its successor,
        // where the store finds it: a commit writes it.
        try write("kept", to: bench.inside(archive, "tree/kept.txt"))
        let second = try bench.store.archive(at: archive)
        #expect(second !== first && second.hasPendingChanges && !first.hasPendingChanges)
        try bench.zip.commit(bench.inside(archive), cancellation: CancellationFlag())
        #expect(listed(archive).contains("tree/kept.txt") && listed(archive).contains("tree/held.txt"))
    }

    @Test func openingManyArchivesNeverDropsOneWithChangesWaiting() throws {
        let archive = try makeZip()
        try write("waiting", to: bench.inside(archive, "tree/waiting.txt"))
        let busy = try bench.store.archive(at: archive)
        for index in 0..<30 {
            let other = box.url("other\(index).zip")
            try FileManager.default.copyItem(at: archive, to: other)
            _ = try bench.store.archive(at: other)
        }
        #expect(try bench.store.archive(at: archive) === busy && busy.hasPendingChanges)
        #expect(bench.store.flushAll().isEmpty && listed(archive).contains("tree/waiting.txt"))
    }

    @Test func writersAndEvictionRaceWithoutLosingAFile() throws {
        let archives = try (0..<16).map { index -> URL in
            let url = box.url("race\(index).zip")
            if index == 0 {
                try box.file("seed/a.txt", "seed")
                #expect(runTool("/usr/bin/zip", ["-qr", "race0.zip", "seed"], in: box.root).status == 0)
            } else {
                try FileManager.default.copyItem(at: box.url("race0.zip"), to: url)
            }
            return url
        }
        // Threads write into some archives while others are opened, which lets the least
        // recently used go. Whatever a write returned without an error must be in the file
        // after the changes were written.
        let lock = NSLock()
        // Guarded by `lock`.
        nonisolated(unsafe) var written: [(archive: URL, name: String)] = []
        // Guarded by `lock`.
        nonisolated(unsafe) var failures: [String] = []
        let (bench, total) = (self.bench, 240)
        DispatchQueue.concurrentPerform(iterations: total) { index in
            let archive = archives[index % archives.count]
            if index % 3 == 0 {
                _ = try? bench.store.archive(at: archives[(index * 7) % archives.count])
                return
            }
            let name = "w\(index).txt"
            do {
                let url = bench.inside(archive, "seed/" + name)
                let writer = try bench.zip.write(url)
                try writer.write(Data("payload \(index)".utf8))
                try writer.close(attributes: FileAttributes())
                lock.lock()
                written.append((archive, name))
                lock.unlock()
            } catch {
                lock.lock()
                failures.append("\(name): \(error)")
                lock.unlock()
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(3))")
        #expect(bench.store.flushAll().isEmpty && !bench.store.hasPendingChanges)
        var names: [URL: Set<String>] = [:]
        for archive in archives { names[archive] = Set(listed(archive)) }
        let missing = written.filter { names[$0.archive]?.contains("seed/" + $0.name) != true }
        #expect(
            missing.isEmpty && written.count == total - total / 3,
            "\(missing.count) of \(written.count) writes are missing")
    }

    // MARK: Pack into an archive on a server (A018, A019, A020, A095)

    @Test func packIntoAnArchiveOnAServerEncryptsWhenAsked() throws {
        let local = try makeZip()
        let onServer = try upload(local, to: "/store/s.zip")
        let secret = try box.file("secret.txt", String(repeating: "top secret line\n", count: 200))
        try bench.pack([secret], to: onServer) {
            $0.password = "pw"
            $0.verifies = true
        }
        let fetched = try download(onServer, as: "s-back.zip")
        let record = try #require(
            ZipDirectory.read(try RandomAccessFile(fetched)).records.first { $0.name == "secret.txt" })
        #expect(record.isEncrypted && record.method == ZipAES.method)
        // Not readable without the password, by anyone.
        #expect(!runTool("/usr/bin/unzip", ["-p", fetched.path, "secret.txt"]).output.contains("top secret"))
        #expect(
            runTool("/usr/bin/bsdtar", ["-xOf", fetched.path, "--passphrase", "pw", "secret.txt"]).output.hasPrefix(
                "top secret line"))
        #expect(!listed(fetched).contains { $0.contains(".afm-") })
    }

    @Test func aFailedPackIntoAnArchiveOnAServerLeavesTheOldMember() throws {
        let local = try makeZip()
        let onServer = try upload(local, to: "/store/s.zip")
        let before = try bench.read(bench.inside(onServer, "tree/readme.txt"))
        // The file that is to replace the member cannot be read.
        let source = try box.folder("again/tree")
        try Data("new readme".utf8).write(to: source.appendingPathComponent("readme.txt"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: source.appendingPathComponent("readme.txt").path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: source.appendingPathComponent("readme.txt").path)
        }
        #expect(throws: (any Error).self) { try bench.pack([source], to: onServer) }
        let open = try bench.store.archive(at: onServer)
        #expect(!open.isBusy)
        #expect(try bench.read(bench.inside(onServer, "tree/readme.txt")) == before)
        #expect(bench.store.flushAll().isEmpty)
        let fetched = try download(onServer, as: "s-after.zip")
        #expect(listed(fetched).contains("tree/readme.txt") && !listed(fetched).contains { $0.contains(".afm-") })
        #expect(runTool("/usr/bin/unzip", ["-tq", fetched.path]).status == 0)

        // Cancelled while the replacement is read: the same.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: source.appendingPathComponent("readme.txt").path)
        bench.monitor.cancellation.cancel()
        let result = Packer(
            fileSystems: bench.fileSystems, store: bench.store, monitor: bench.monitor, options: PackOptions()
        )
        .run([try bench.item(source)], archive: onServer)
        #expect(result.cancelled || result.failure != nil)
        #expect(try bench.read(bench.inside(onServer, "tree/readme.txt")) == before && !open.isBusy)
    }

    // MARK: The archive file itself (A034, A035, A037, A047, A079)

    @Test func anArchiveReachedThroughALinkIsChangedWhereItLies() throws {
        let archive = try makeZip()
        try box.folder("real")
        let real = box.url("real/real.zip")
        try FileManager.default.moveItem(at: archive, to: real)
        let link = box.url("link.zip")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        func isLink() -> Bool { (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil }
        // A change made inside, through the link…
        try write("through the link", to: bench.inside(link, "tree/via-link.txt"))
        #expect(bench.store.flushAll().isEmpty)
        #expect(isLink() && listed(real).contains("tree/via-link.txt"))
        // …a deletion, which writes the whole archive anew…
        try bench.zip.remove(bench.inside(link, "tree/empty.txt"))
        #expect(bench.store.flushAll().isEmpty)
        #expect(isLink() && !listed(real).contains("tree/empty.txt"))
        // …and packing into it, by adding and by replacing a member.
        let extra = try box.file("extra.txt", "extra")
        try bench.pack([extra], to: link)
        #expect(isLink() && listed(real).contains("extra.txt"))
        try Data("extra, again".utf8).write(to: extra)
        try bench.pack([extra], to: link)
        #expect(isLink() && runTool("/usr/bin/unzip", ["-p", real.path, "extra.txt"]).output == "extra, again")
        #expect(Durable.realFile(link).path == Durable.realFile(real).path)
    }

    @Test func anArchiveKeepsItsRightsAndANewOneIsNoMoreOpenThanItsSources() throws {
        let archive = try makeZip()
        func mode(_ url: URL) -> Int {
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        // Added to (the file is cloned and continued), and with a member replaced (written anew).
        let extra = try box.file("extra.txt", "extra")
        try bench.pack([extra], to: archive)
        #expect(mode(archive) == 0o600 && listed(archive).contains("extra.txt"))
        try Data("again".utf8).write(to: extra)
        try bench.pack([extra], to: archive)
        #expect(mode(archive) == 0o600)
        // Without cloning: every write is a new file.
        bench.environment.clonesArchives = false
        try bench.pack([try box.file("third.txt", "third")], to: archive)
        #expect(mode(archive) == 0o600 && listed(archive).contains("third.txt"))
        try bench.zip.remove(bench.inside(archive, "third.txt"))
        #expect(bench.store.flushAll().isEmpty && mode(archive) == 0o600)
        // A new archive of private files is private; one of public files is as before.
        let secret = try box.file("private/secret.txt", "secret")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret.path)
        try bench.pack([secret], to: box.url("private.zip"))
        try bench.pack([extra], to: box.url("public.zip"))
        #expect(mode(box.url("private.zip")) == 0o600)
        #expect(
            mode(box.url("public.zip")) & 0o600 == 0o600
                && mode(box.url("public.zip")) & 0o044 == (0o044 & ~Int(umaskNow())))
        // No temporary file of a write is left next to the archives.
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.root.path).allSatisfy { !$0.hasSuffix(".tmp") })
    }

    private func umaskNow() -> mode_t {
        let mask = umask(0)
        umask(mask)
        return mask
    }

    @Test func packIntoAnArchiveWithChangesWaitingLosesNeither() throws {
        let archive = try makeZip()
        // A change that waits in the open archive, then a pack that rewrites the file.
        try write("waiting", to: bench.inside(archive, "tree/waiting.txt"))
        try bench.pack([try box.file("packed.txt", "packed")], to: archive)
        #expect(bench.store.flushAll().isEmpty)
        #expect(listed(archive).contains("tree/waiting.txt") && listed(archive).contains("packed.txt"))
        // A file that someone else replaces while the pack writes is not overwritten.
        var replaced = false
        let stranger = try Data(contentsOf: archive)
        let packer = Packer(
            fileSystems: bench.fileSystems, store: bench.store, monitor: bench.monitor, options: PackOptions())
        let source = try box.file("late.txt", "late")
        // (The moment between the pack's own writing and its putting the file in place is
        // not reachable from here; the check it makes there is.)
        let open = try bench.store.archive(at: archive)
        #expect(throws: ArchiveError.self) {
            try open.whileHoldingFile(cancellation: nil) { stillUnchanged in
                try stranger.write(to: box.url("stranger.zip"))
                #expect(rename(box.url("stranger.zip").path, archive.path) == 0)
                replaced = true
                try stillUnchanged()
            }
        }
        #expect(replaced)
        _ = (packer, source)
    }

    @Test func aDamagedDirectoryCannotMakeAWriteOverwriteAnotherMember() throws {
        // Two members; the directory's entry for the second points at the first one's header.
        let url = box.url("crossed.zip")
        let output = try OutputFile(creating: url)
        let writer = ZipWriter(output)
        var first = ZipRecord.new(
            name: "first.txt", isDirectory: false, modified: Date(timeIntervalSince1970: 1_600_000_000),
            permissions: 0o644)
        let payload = Data("first member data".utf8)
        (first.crc, first.compressedSize, first.uncompressedSize) = (
            CRC32.of(payload), UInt64(payload.count), UInt64(payload.count)
        )
        let opened = try writer.begin(first)
        try writer.append(payload)
        try writer.end(opened, first, headerChanged: false)
        var second = ZipRecord.new(
            name: "second.txt", isDirectory: false, modified: Date(timeIntervalSince1970: 1_600_000_000),
            permissions: 0o644)
        (second.crc, second.compressedSize, second.uncompressedSize) = (
            first.crc, first.compressedSize, first.uncompressedSize
        )
        writer.adopt(second, at: 0)
        try writer.finish()
        try output.close()
        let before = try Data(contentsOf: url)
        // Changing the time of the second would patch the header at the offset it claims.
        try bench.zip.setAttributes(
            FileAttributes(modified: Date(timeIntervalSince1970: 1_700_000_000)), of: bench.inside(url, "second.txt"))
        _ = bench.store.flushAll()
        let after = try Data(contentsOf: url)
        // Whatever the write did, the first member's header and data are what they were.
        #expect(after.prefix(30 + 9 + first.extra.count + payload.count).prefix(26) == before.prefix(26))
        #expect(runTool("/usr/bin/unzip", ["-p", url.path, "first.txt"]).output == "first member data")
    }

    // MARK: The main thread (A003, A004, A015, A054, A091)

    @Test func capabilitiesAnswerWhileAWriteIsUnderWay() throws {
        let archive = try makeZip()
        try write("pending", to: bench.inside(archive, "tree/pending.txt"))
        let (entered, release) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
        bench.environment.whileWriting = {
            entered.signal()
            release.wait()
        }
        let done = DispatchSemaphore(value: 0)
        let store = bench.store
        Thread.detachNewThread {
            _ = store.flushAll()
            done.signal()
        }
        entered.wait()
        // The write holds its gate now. What the main thread asks answers all the same.
        let root = bench.inside(archive)
        #expect(bench.zip.capabilities(for: root) == [.write, .deferredWrites])
        #expect(bench.store.openArchive(at: archive)?.capabilities == [.write, .deferredWrites])
        // A rename that would write at once does not wait behind the write either.
        try write("second", to: bench.inside(archive, "tree/.afm-\(UUID().uuidString).tmp"))
        release.signal()
        done.wait()
        bench.environment.whileWriting = nil
        #expect(listed(archive).contains("tree/pending.txt"))
    }

    // MARK: Rescue (A078, A082)

    @Test func membersThatAreKeptComeWithAListOfWhatTheyAre() throws {
        let archive = try makeZip()
        try write("unsaved one", to: bench.inside(archive, "tree/one.txt"))
        try write("on its way", to: bench.inside(archive, "tree/.afm-\(UUID().uuidString).tmp"))
        let open = try bench.store.archive(at: archive)
        guard case .kept(let folder) = open.rescue(quickly: true) else {
            Issue.record("the members were not kept")
            return
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        let lists = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("index-") }
        let index = try String(contentsOf: folder.appendingPathComponent(try #require(lists.first)), encoding: .utf8)
        // The member with its name, and not the one a job had not finished.
        #expect(
            index.contains("\ttree/one.txt\t") && !index.contains(".afm-") && index.contains(archive.lastPathComponent))
        let file = try #require(index.split(separator: "\n").last?.split(separator: "\t").first)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(String(file)).path))
    }

    // MARK: The gate

    @Test func aWaitForARunningWriteEndsWhenItIsCancelled() throws {
        let archive = try makeZip()
        try write("pending", to: bench.inside(archive, "tree/pending.txt"))
        let (entered, release) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
        bench.environment.whileWriting = {
            entered.signal()
            release.wait()
        }
        let done = DispatchSemaphore(value: 0)
        let store = bench.store
        Thread.detachNewThread {
            _ = store.flushAll()
            done.signal()
        }
        entered.wait()
        let open = try #require(bench.store.openArchive(at: archive))
        let flag = CancellationFlag()
        flag.cancel()
        // A second write (a commit, the quit) that is cancelled does not wait for the first.
        #expect { try open.flush(cancellation: flag) } throws: { error in
            if case ArchiveError.cancelled = error { return true }
            return false
        }
        // And the rescue waits no longer than it is given.
        if case .nothingToSave = open.rescue(quickly: true, before: Date()) {
            Issue.record("the pending member was not seen")
        }
        release.signal()
        done.wait()
        bench.environment.whileWriting = nil
    }
}
