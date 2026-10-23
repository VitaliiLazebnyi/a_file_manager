import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FilePropertiesPlugin

/// Second pass of review round 2 for the file properties: work below a folder that stopped answering ends with
/// its job (V070, T024, T047), trees are changed on all cores, and the comment files (G002).
@Suite
internal struct Review2FileopsP2PropertiesTests {
    /// The temporary folder on the local disk.
    internal let box: Sandbox
    /// Knows the local disk, `memory` and `probe`.
    internal let fileSystems = FileSystemRegistry()
    /// A memory file system with the scheme `mem`.
    internal let memory = MemoryFileSystem()
    /// A memory file system that notes how it is called.
    internal let probe = P2ProbeFileSystem()

    /// A fresh sandbox and the three file systems, registered.
    internal init() throws {
        box = try Sandbox()
        fileSystems.register(LocalFileSystem())
        fileSystems.register(memory)
        fileSystems.register(probe)
    }

    /// The bytes as UTF-8 text, every malformed sequence replaced by U+FFFD the way `String(decoding:as:)` does.
    private static func lossyText(_ bytes: some Collection<UInt8>) -> String {
        var decoder = UTF8()
        var iterator = bytes.makeIterator()
        var scalars = String.UnicodeScalarView()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar):
                scalars.append(scalar)

            case .error:
                scalars.append("\u{FFFD}")

            case .emptyInput:
                return String(scalars)
            }
        }
    }

    /// Measuring a folder on a server that stopped answering ends with the job, and nothing counts as unreadable
    /// (V070, T024).
    @Test
    internal func measuringAFolderOnAServerThatStoppedAnsweringEndsWithTheJob() throws {
        memory.addFile("/s/dir/sub/f.txt", "12345")
        memory.addFile("/s/file.txt", "123")
        let items = try memory.list(memory.url("/s"), showHidden: true)
        let flag = CancellationFlag()
        let calculator = SpaceCalculator(fileSystems: fileSystems, cancellation: flag)
        #expect(calculator.measure(items).reduce(SpaceTotals(), +).bytes == 8)
        memory.stallsListings = true
        // Written by the other thread before the wait ends, read here after it.
        nonisolated(unsafe) var totals: [SpaceTotals] = []
        P2Wait.cancel(flag, after: 0.2)
        let ended = P2Wait.finishes(
            rescue: { memory.releaseStalls() },
            work: { totals = calculator.measure(items) }
        )
        #expect(ended)
        // What was not read is not "unreadable": the calculation was stopped, and says so elsewhere.
        #expect(totals.reduce(SpaceTotals(), +).unreadable == 0 && totals.count == items.count)
    }

    /// Changing attributes below a folder that stopped answering ends with the job, and nothing counts as failed
    /// (V070, T024, T047).
    @Test
    internal func changingAttributesBelowAFolderThatStoppedAnsweringEndsWithTheJob() throws {
        memory.addFile("/s/dir/sub/f.txt")
        let items = try memory.list(memory.url("/s"), showHidden: true)
        memory.stallsListings = true
        let flag = CancellationFlag()
        var change = AttributeChange()
        change.recurse = true
        change.timestamp = .current
        let job = AttributeJob(change: change, fileSystems: fileSystems, cancellation: flag, meter: nil)
        // Written by the other thread before the wait ends, read here after it.
        nonisolated(unsafe) var outcome = AttributeJob.Outcome()
        P2Wait.cancel(flag, after: 0.2)
        let ended = P2Wait.finishes(rescue: { memory.releaseStalls() }, work: { outcome = job.run(items) })
        #expect(ended && outcome.cancelled)
        // Nothing "failed": the job was stopped.
        #expect(outcome.failed == 0 && outcome.failures.isEmpty)
    }

    /// A tree is changed on all cores with nothing left out.
    @Test
    internal func aTreeIsChangedOnAllCoresWithNothingLeftOut() throws {
        // Folders in folders, each with files: the calls for them are made from inside calls.
        var files = 0
        var folders = 1
        for upper in 0..<6 {
            folders += 1
            for lower in 0..<5 {
                folders += 1
                for index in 0..<70 {
                    try box.file("tree/a\(upper)/b\(lower)/f\(index).txt", "x")
                    files += 1
                }
            }
            try box.file("tree/a\(upper)/own.txt", "x")
            files += 1
        }
        let items = try LocalFileSystem().list(box.root, showHidden: true).filter { $0.name == "tree" }
        var change = AttributeChange()
        change.recurse = true
        change.permissions = try #require(PermissionChange("go-rwx"))
        let outcome = AttributeJob(
            change: change,
            fileSystems: fileSystems,
            cancellation: CancellationFlag(),
            meter: nil
        )
        .run(items)
        #expect(outcome.changed == files + folders && outcome.failed == 0 && !outcome.cancelled)
        var info = stat()
        #expect(lstat(box.url("tree/a5/b4/f69.txt").path, &info) == 0 && info.st_mode & 0o077 == 0)
        #expect(lstat(box.url("tree/a0/b0").path, &info) == 0 && info.st_mode & 0o077 == 0)
    }

    /// Nobody waits for ever for a comment file that is not coming: neither a thread with a flag, nor one
    /// without (V070, the comment column's threads).
    @Test
    internal func nobodyWaitsForEverForACommentFileThatIsNotComing() {
        probe.base.addFile("/A/descript.ion", "a.txt the comment\r\n")
        probe.base.addFile("/A/a.txt")
        let store = CommentStore(fileSystems: fileSystems)
        let folder = probe.base.url("/A")
        #expect(store.comments(in: folder, cancellation: CancellationFlag())["a.txt"] == "the comment")
        store.forget(folder)
        let alreadyRead = probe.reads.count
        // From now on the file does not arrive: its reads wait until they are interrupted.
        probe.base.stallsReads = true
        let (first, second) = (CancellationFlag(), CancellationFlag())
        // Guarded by `lock`.
        nonisolated(unsafe) var answers: [[String: String]] = [[:], [:], [:]]
        let lock = NSLock()
        let reader = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let comments = store.comments(in: folder, cancellation: first)
            lock.withLock { answers[0] = comments }
            reader.signal()
        }
        // The first thread has the file open before the others ask.
        for _ in 0..<60_000 where probe.reads.count == alreadyRead { usleep(1_000) }
        #expect(probe.reads.count == alreadyRead + 1)
        // A thread that waits for that reading gives up when its own flag is set…
        P2Wait.cancel(second, after: 0.1)
        let flaggedEnded = P2Wait.finishes(
            rescue: { probe.base.releaseStalls() },
            work: {
                let comments = store.comments(in: folder, cancellation: second)
                lock.withLock { answers[1] = comments }
            }
        )
        #expect(flaggedEnded)
        // …and one without a flag when its patience runs out.
        store.waitLimit = 0.2
        let patientEnded = P2Wait.finishes(
            rescue: { probe.base.releaseStalls() },
            work: {
                let comments = store.comments(in: folder, cancellation: CancellationFlag())
                lock.withLock { answers[2] = comments }
            }
        )
        #expect(patientEnded)
        // Nobody opened the file a second time meanwhile.
        #expect(probe.reads.count == alreadyRead + 1)
        // The reader itself ends with its flag, and what it did not read is not remembered.
        first.cancel()
        #expect(reader.wait(timeout: .now() + 60) == .success)
        #expect(lock.withLock { answers } == [[:], [:], [:]])
        probe.base.stallsReads = false
        #expect(store.comments(in: folder, cancellation: CancellationFlag())["a.txt"] == "the comment")
    }

    /// A comment that is being saved is not written from a reading that was stopped.
    @Test
    internal func aCommentThatIsBeingSavedIsNotWrittenFromAReadingThatWasStopped() throws {
        memory.addFile("/A/descript.ion", "a.txt old\r\nb.txt other\r\n")
        let store = CommentStore(fileSystems: fileSystems)
        let flag = CancellationFlag()
        flag.cancel()
        #expect(throws: (any Error).self) {
            try store.setComment("new", for: "a.txt", in: memory.url("/A"), hidden: false, cancellation: flag)
        }
        #expect(memory.contents("/A/descript.ion") == "a.txt old\r\nb.txt other\r\n")
        #expect(memory.allPaths.filter { $0.hasPrefix("/A/") } == ["/A/descript.ion"])
        try store.setComment("new", for: "a.txt", in: memory.url("/A"), hidden: false, cancellation: CancellationFlag())
        #expect(memory.contents("/A/descript.ion") == "a.txt new\r\nb.txt other\r\n")
    }

    /// The comment files that were misread or lost are read and rewritten whole: the six reproducers the fuzzer
    /// kept (G002), through the checks that failed.
    @Test
    internal func theCommentFilesThatWereMisreadOrLostAreReadAndRewrittenWhole() throws {
        func bytes(_ name: String) throws -> [UInt8] {
            let file = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Fuzz/repro/misc/\(name)")
            return Array(try Data(contentsOf: file))
        }
        // One well-formed line: a name without separators, a space, a comment.
        for (name, quoted) in [
            ("descript-line-misread-prepend-char.bin", false),
            ("descript-quoted-line-misread-combining-mark.bin", true)
        ] {
            let input = try bytes(name)
            let take = min(Int(input[0] % 32), input.count - 1)
            var fileName = Self.lossyText(input[1..<(1 + take)])
            fileName.unicodeScalars.removeAll { " \"\r\n".unicodeScalars.contains($0) || $0.value == 0xFEFF }
            var comment = Self.lossyText(input[(1 + take)...])
            comment.unicodeScalars.removeAll { "\r\n".unicodeScalars.contains($0) }
            comment = DescriptIon.normalized(comment)
            // The harness leaves such inputs out; the reproducers are not among them.
            try #require(!fileName.isEmpty && !comment.isEmpty)
            let line = (quoted ? "\"" + fileName + "\"" : fileName) + " " + comment + "\r\n"
            let file = DescriptIon(data: Data([0xEF, 0xBB, 0xBF] + Array(line.utf8)))
            #expect(file.entries.count == 1, "\(name)")
            #expect(file.entries.first.map { Array($0.name.utf8) } == Array(fileName.utf8), "\(name)")
            #expect(file.entries.first.map { Array($0.comment.utf8) } == Array(comment.utf8), "\(name)")
        }
        // Written again, as any change of a comment does, every entry is still there.
        for name in ["descript-rewrite-bom-collision.bin", "descript-rewrite-prepend-char.bin"] {
            let data = Data(try bytes(name))
            let file = DescriptIon(data: data)
            #expect(!file.entries.isEmpty && DescriptIon(strict: data) == file, "\(name)")
            #expect(DescriptIon(data: file.data()).entries == file.entries, "\(name)")
        }
        // Through the store: a comment is added and every other one is as it was.
        for name in ["descript-store-bom-name-lost.bin", "descript-store-file-unreadable-after-edit.bin"] {
            memory.removeTree("/d")
            let folder = memory.addDirectory("/d")
            let writer = try memory.write(folder.appending(name: DescriptIon.fileName))
            try writer.write(Data(try bytes(name)))
            try writer.close(attributes: FileAttributes())
            let (store, flag) = (CommentStore(fileSystems: fileSystems), CancellationFlag())
            let before = store.comments(in: folder, cancellation: flag)
            try store.setComment("fresh\ncomment", for: "new.txt", in: folder, hidden: false, cancellation: flag)
            let after = store.comments(in: folder, cancellation: flag)
            #expect(after["new.txt"] == "fresh\ncomment", "\(name)")
            for (entry, comment) in before where entry != "new.txt" {
                #expect(after[entry] == comment, "\(name): \(entry.debugDescription)")
            }
            #expect(after.count == before.count + (before["new.txt"] == nil ? 1 : 0), "\(name)")
        }
    }
}
