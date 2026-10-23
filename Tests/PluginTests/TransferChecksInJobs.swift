import AFMKernel
import FileOperationsPlugin
import Foundation
import TestSupport
import Testing

/// The options of the Copy dialog that check and report: verify, checksums, errors, part files, the log's records.
@Suite
internal struct TransferChecksInJobs {
    /// Verify finds a damaged copy, removes it, and a verified move keeps its source until the copy is good.
    @Test
    internal func verifyCatchesACorruptedCopy() throws {
        let box = try Sandbox()
        let (fileSystems, wrapped) = makeWrappedFileSystems()
        try box.file("A/data.bin", String(repeating: "d", count: 3_000))
        wrapped.base.addDirectory("/inbox")
        let source = [box.url("A/data.bin")]
        let target = TargetSpec(directory: wrapped.base.url("/inbox"))

        wrapped.corruptsWrites = true
        // Without Verify the damage goes unnoticed.
        Replies().run(.copy, source, to: target, fileSystems: fileSystems, configure: nil)
        // (The damaged bytes are no text any more, so there is nothing to read back as a string.)
        #expect(
            wrapped.base.item(at: wrapped.base.url("/inbox/data.bin"))?.size == 3_000
                && wrapped.base.contents("/inbox/data.bin") == nil
        )
        wrapped.base.removeTree("/inbox/data.bin")

        let replies = Replies()
        let failed = replies.run(.copy, source, to: target, fileSystems: fileSystems) { job in
            job.options.verifies = true
        }
        #expect(replies.errors.count == 1 && replies.errors[0].hasPrefix("Verify failed"))
        // Neither the damaged file nor its temporary name remains, and the source is untouched.
        #expect(wrapped.base.allPaths == ["/inbox"] && failed.completed.isEmpty && failed.failureCount == 1)
        #expect(box.read("A/data.bin")?.count == 3_000)

        // A verified move keeps the source when the copy is bad, and removes it when it is good.
        let moving = Replies()
        moving.run(.move, source, to: target, fileSystems: fileSystems) { $0.options.verifies = true }
        #expect(box.exists("A/data.bin") && wrapped.base.allPaths == ["/inbox"])
        wrapped.corruptsWrites = false
        let good = Replies()
            .run(.move, source, to: target, fileSystems: fileSystems) { job in
                job.options.verifies = true
            }
        #expect(
            good.completed.count == 1 && !box.exists("A/data.bin")
                && wrapped.base.contents("/inbox/data.bin")?.count == 3_000
        )
    }

    /// Checksums tell equal contents from different ones, stop when asked to, and give the SHA-256 of a file.
    @Test
    internal func checksumsCompareContents() throws {
        let (fileSystems, memory) = makeFileSystems()
        let box = try Sandbox()
        try box.file("a.txt", "same")
        memory.addFile("/b.txt", "same")
        memory.addFile("/c.txt", "samf")
        #expect(try Checksum.sameContents(box.url("a.txt"), memory.url("/b.txt"), in: fileSystems) == .same)
        #expect(try Checksum.sameContents(box.url("a.txt"), memory.url("/c.txt"), in: fileSystems) == .different)
        let stopped = try Checksum.sameContents(box.url("a.txt"), memory.url("/b.txt"), in: fileSystems) { true }
        #expect(stopped == .cancelled)
        let digest = try Checksum.sha256(of: memory.url("/b.txt"), in: fileSystems)
        let hex = digest?.map { String(format: "%02x", $0) }.joined()
        #expect(hex?.hasPrefix("0967115f") == true)
    }

    /// With Skip All Errors a missing source is counted and named, not asked about.
    @Test
    internal func keepingGoingOnErrorsSkipsWithoutAskingAndCounts() {
        let (fileSystems, memory) = makeFileSystems()
        memory.addFile("/a/one.txt", "1")
        memory.addDirectory("/b")
        let replies = Replies()
        let result = replies.run(
            .copy,
            [memory.url("/a/gone.txt"), memory.url("/a/one.txt")],
            to: TargetSpec(directory: memory.url("/b")),
            fileSystems: fileSystems
        ) { $0.options.skipsErrors = true }
        #expect(
            replies.errors.isEmpty && result.failureCount == 1 && result.failures.first?.contains("gone.txt") == true
        )
        #expect(memory.exists("/b/one.txt") && result.completed.count == 1)
    }

    /// A cancelled copy can keep its part file, and Resume completes it to the whole contents.
    @Test
    internal func aPartFileCanBeKeptAndResumed() throws {
        let box = try Sandbox()
        let (fileSystems, memory) = makeFileSystems()
        let content = String(repeating: "0123456789abcdef", count: (5 << 20) / 16)
        try box.file("A/big.bin", content)
        memory.addDirectory("/inbox")
        let target = TargetSpec(directory: memory.url("/inbox"))
        let replies = Replies()
        replies.cancelAtBytes = 2 << 20
        let cancelled = replies.run(.copy, [box.url("A/big.bin")], to: target, fileSystems: fileSystems) { job in
            job.options.keepsPartialFiles = true
        }
        let partial = memory.item(at: memory.url("/inbox/big.bin"))?.size ?? 0
        #expect(
            cancelled.cancelled && partial > 0 && partial < Int64(content.count)
                && memory.allPaths == ["/inbox", "/inbox/big.bin"]
        )
        let resumed = Replies(.resume)
            .run(.copy, [box.url("A/big.bin")], to: target, fileSystems: fileSystems) { $0.options.verifies = true }
        #expect(resumed.completed.count == 1 && memory.contents("/inbox/big.bin") == content)
    }

    /// Every copied, skipped, failed, deleted and appended item becomes a record for the log.
    @Test
    internal func everyItemIsRecordedForTheLog() {
        let (fileSystems, memory) = makeFileSystems()
        memory.addFile("/a/docs/in.txt", "1")
        memory.addFile("/a/one.txt", "new")
        memory.addFile("/b/one.txt", "old")
        let lock = NSLock()
        // Guarded by `lock`.
        nonisolated(unsafe) var lines: [String] = []
        let collect = { @Sendable (record: OperationRecord) in
            lock.withLock { lines.append(OperationLog.line(for: record, at: "T")) }
        }
        let sources = [memory.url("/a/docs"), memory.url("/a/one.txt"), memory.url("/a/gone.txt")]
        Replies(.skip)
            .run(.copy, sources, to: TargetSpec(directory: memory.url("/b")), fileSystems: fileSystems) { job in
                job.onRecord = collect
            }
        #expect(
            Set(lines) == [
                "T: New folder: mem:/b/docs\n", "T: Copy: mem:/a/docs/in.txt -> mem:/b/docs/in.txt\n",
                "T: Skipped: Copy: mem:/a/one.txt -> mem:/b/one.txt\n",
                "T: Error: Copy: mem:/a/gone.txt: mem:/a/gone.txt does not exist any more!\n",
                "T: Skipped: Copy: mem:/a/gone.txt\n"
            ]
        )
        lines = []
        Replies()
            .run(.delete(toTrash: false), [memory.url("/b/docs")], to: nil, fileSystems: fileSystems) { job in
                job.onRecord = collect
            }
        #expect(lines == ["T: Delete: mem:/b/docs/in.txt\n", "T: Delete folder: mem:/b/docs\n"])
        lines = []
        Replies(.append)
            .run(
                .move,
                [memory.url("/a/one.txt")],
                to: TargetSpec(directory: memory.url("/b")),
                fileSystems: fileSystems
            ) { job in
                job.onRecord = collect
            }
        #expect(
            lines == ["T: Append: mem:/a/one.txt -> mem:/b/one.txt\n"] && memory.contents("/b/one.txt") == "oldnew"
                && !memory.exists("/a/one.txt")
        )
    }
}
