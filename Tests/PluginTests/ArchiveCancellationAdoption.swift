import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Runs `body` on a thread of its own once `condition` holds, or after a long wait: the request
/// to stop comes from outside the thread that is stuck, and not from a queue that may stall.
private func signal(when condition: @escaping @Sendable () -> Bool, then body: @escaping @Sendable () -> Void) {
    let thread = Thread {
        let deadline = Date().addingTimeInterval(Wait.ceiling)
        while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        body()
    }
    thread.start()
}

/// Waits for `condition`, up to `Wait.ceiling`.
private func wait(for condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(Wait.ceiling)
    while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    return condition()
}

/// The kernel's cancellation, as the archives adopt it: long reads, child processes, openings and fetches end when the
/// request comes.
@Suite
internal struct ArchiveCancellationAdoption: ArchiveFixSuite {
    /// The archive file systems and the sandbox of the test.
    internal let bench: ArchiveBench

    /// What the temporary folder of the archives holds.
    internal var scratchFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: bench.environment.scratch.url.path)) ?? [])
    }

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// Decompressing and skipping through a stream that never ends stop when the request comes from another thread.
    @Test
    internal func decompressionAndSkippingEndWhenTheRequestComes() throws {
        let source = EndlessDeflate()
        let control = StreamInterrupt()
        let stream = InflateStream(source, wrapping: .raw, control: control)
        #expect(try stream.read(upToCount: 1_000)?.count == 1_000)
        signal(when: { source.reads.value > 50 }, then: { control.set() })
        // Skipping through what never ends: it ends because the request comes from another thread.
        #expect(throws: ArchiveError.self) { try stream.skip(.max) }
        #expect(throws: ArchiveError.self) { _ = try stream.read(upToCount: 10) }
    }

    /// A member reader that is interrupted from another thread is ended and stays ended.
    @Test
    internal func aReaderIsEndedFromAnotherThreadAndStaysEnded() throws {
        let source = EndlessDeflate()
        let reader = try ArchiveMemberReader(cancellation: nil) { slot in
            let control = StreamInterrupt()
            slot.use(control)
            return InflateStream(source, wrapping: .raw, control: control)
        }
        #expect(try reader.read(upToCount: 100)?.count == 100)
        signal(when: { source.reads.value > 50 }, then: { reader.interrupt() })
        #expect(throws: ArchiveError.self) { try reader.seek(to: .max / 2) }
        #expect(throws: ArchiveError.self) { _ = try reader.read(upToCount: 10) }
        #expect(throws: ArchiveError.self) { try reader.seek(to: 0) }
        reader.close()
    }

    /// A child process that waits for a reader is stopped by the request to stop.
    @Test
    internal func aChildProcessIsStoppedByTheRequest() throws {
        // Two hundred megabytes of zeros decompress to more than the pipe holds: bzip2 waits
        // for whoever reads, which here is nobody, until it is stopped.
        let zeros = box.url("zeros.bz2")
        #expect(
            runTool("/bin/sh", ["-c", "head -c 200000000 /dev/zero | /usr/bin/bzip2 -1 > '\(zeros.path)'"]).status == 0
        )
        let control = StreamInterrupt()
        let stream = try ProcessStream(Tool.bzip2, ["-dc", "--", zeros.path], control: control)
        defer { stream.close() }
        func running() -> Bool { runTool("/usr/bin/pgrep", ["-f", "bzip2 -dc -- \(zeros.path)"]).status == 0 }
        #expect(wait(for: running))
        control.set()
        #expect(wait { !running() })
        #expect(throws: ArchiveError.self) { _ = try stream.read(upToCount: 10) }
    }

    /// A member read from a compressed stream ends when it is interrupted and leaves the next reads alone; a set flag
    /// stops the opening of a member.
    @Test
    internal func aMemberReadFromAStreamEndsWhenInterruptedAndLeavesTheNextReadsAlone() throws {
        bench.environment.materializeLimit = 0
        let tree = try bench.makeTree()
        let archive = box.url("tree.tar.gz")
        try bench.pack([tree], to: archive) { $0.format = .compressedTar(.gzip) }
        let root = bench.inside(archive, "tree", scheme: ArchiveURL.readOnlyScheme)
        let opened = try bench.store.archive(at: archive, cancellation: nil)
        #expect(!opened.allowsParallelReads)
        let big = try Data(contentsOf: tree.appendingPathComponent("big.log"))
        let readme = try Data(contentsOf: tree.appendingPathComponent("readme.txt"))
        let flag = CancellationFlag()

        // Interrupted in the middle of a member: ended, and so is everything after.
        let first = try bench.readOnly.read(root.appending(name: "big.log"), cancellation: flag)
        #expect(try first.read(upToCount: 1_000)?.count == 1_000)
        first.interrupt()
        #expect(throws: ArchiveError.self) { _ = try first.read(upToCount: 10) }
        #expect(throws: ArchiveError.self) { try first.seek(to: 0) }
        first.close()

        // It was not kept for the next read, which starts the stream again and gets everything.
        let starts = opened.streamStarts
        #expect(try bench.read(root.appending(name: "big.log")) == big)
        #expect(opened.streamStarts == starts + 1)

        // A reader that finished is kept for the one after it; interrupting the finished one
        // later does not end the other's read.
        let done = try bench.readOnly.read(root.appending(name: "big.log"), cancellation: flag)
        while try done.read(upToCount: 1 << 20) != nil {
            // Read to the end.
        }
        done.close()
        let starts2 = opened.streamStarts
        let next = try bench.readOnly.read(root.appending(name: "readme.txt"), cancellation: flag)
        #expect(opened.streamStarts == starts2)
        done.interrupt()
        var bytes = Data()
        while let block = try next.read(upToCount: 1 << 16) { bytes.append(block) }
        next.close()
        #expect(bytes == readme)

        // A flag that is set stops the opening of a member.
        flag.cancel()
        #expect(throws: (any Error).self) {
            _ = try bench.readOnly.read(root.appending(name: "readme.txt"), cancellation: flag)
        }
    }

    /// Opening a compressed archive can be abandoned, and leaves nothing half-open behind.
    @Test(arguments: [
        ArchiveFormat.compressedTar(.gzip), .compressedTar(.xzStream), .compressedTar(.bzip2), .compressedFile(.bzip2)
    ])
    internal func openingAStreamArchiveCanBeAbandoned(format: ArchiveFormat) throws {
        // Materialising, or counting the size of a file that does not say it, are the long parts.
        bench.environment.materializeLimit = format == .compressedFile(.bzip2) ? 0 : 1 << 30
        let tree = try bench.makeTree()
        let archive = box.url("tree." + format.defaultExtension)
        if case .compressedFile = format {
            try bench.pack([tree.appendingPathComponent("big.log")], to: archive) { $0.format = format }
        } else {
            try bench.pack([tree], to: archive) { $0.format = format }
        }
        let flag = CancellationFlag()
        flag.cancel()
        #expect(throws: ArchiveError.self) { _ = try bench.store.archive(at: archive, cancellation: flag) }
        // Nothing half-open is kept: not the archive, not a failure to open it, not a temporary file.
        #expect(bench.store.openArchive(at: archive) == nil && scratchFiles.isEmpty)
        let root = bench.inside(archive, scheme: ArchiveURL.readOnlyScheme)
        #expect(throws: ArchiveError.self) { _ = try bench.readOnly.list(root, showHidden: true, cancellation: flag) }
        #expect(throws: ArchiveError.self) {
            try bench.readOnly.list(root, showHidden: true, cancellation: flag) { _ in true }
        }
        #expect(bench.readOnly.item(at: root, cancellation: flag) == nil)
        #expect(throws: ArchiveError.self) { _ = try bench.readOnly.read(root, cancellation: flag) }
        #expect(try !bench.names(root).isEmpty)
        #expect(bench.store.openArchive(at: archive) != nil)
    }

    /// Fetching an archive from a server that never answers can be abandoned, and leaves nothing behind.
    @Test
    internal func fetchingAnArchiveFromAServerCanBeAbandoned() throws {
        let tree = try bench.makeTree()
        let onServer = bench.memory.url("/store/tree.zip")
        try bench.pack([tree], to: onServer)
        bench.store.close()
        bench.memory.stallsReads = true
        let flag = CancellationFlag()
        // The server never answers; the request comes from a thread of its own.
        signal(when: { true }, then: { flag.cancel() })
        let root = ArchiveURL.make(scheme: "zip", archive: onServer, innerPath: "")
        #expect(throws: ArchiveError.self) { _ = try bench.zip.list(root, showHidden: true, cancellation: flag) }
        #expect(bench.store.openArchive(at: onServer) == nil && scratchFiles.isEmpty)
        bench.memory.stallsReads = false
        bench.memory.releaseStalls()
        #expect(try bench.names(root) == ["tree"])
    }

    /// Calls for places outside the archive go to the file system they lie on, with the flag, and its readers end at
    /// its interrupt.
    @Test
    internal func callsOutsideTheArchiveGoToTheFileSystemWithTheFlag() throws {
        let tree = try bench.makeTree()
        let onServer = bench.memory.url("/store/tree.zip")
        try bench.pack([tree], to: onServer)
        let root = ArchiveURL.make(scheme: "zip", archive: onServer, innerPath: "")
        _ = bench.memory.addFile("/store/log.txt", String(repeating: "x", count: 1_000))
        let place = try outside(root, "/store/log.txt")
        #expect(bench.zip.item(at: place, cancellation: CancellationFlag())?.size == 1_000)
        #expect(
            try bench.zip.list(try outside(root, "/store"), showHidden: true, cancellation: CancellationFlag())
                .map(
                    \.name
                )
                .sorted()
                == ["log.txt", "tree.zip"]
        )
        let cancelled = CancellationFlag()
        cancelled.cancel()
        #expect(bench.zip.item(at: place, cancellation: cancelled) == nil)

        // The reader and writer are the other file system's own, and are ended by its interrupt.
        bench.memory.stallsReads = true
        let reader = try bench.zip.read(place, cancellation: CancellationFlag())
        let tie = CancellationFlag()
        let held = tie.interrupting(reader)
        signal(when: { true }, then: { tie.cancel() })
        #expect(throws: MemoryFileSystem.Interrupted.self) { _ = try reader.read(upToCount: 10) }
        withExtendedLifetime(held) { bench.memory.stallsReads = false }
    }

    /// A member writer ends when it is interrupted, and nothing of it joins the archive.
    @Test
    internal func aMemberWriterEndsWhenInterrupted() throws {
        let archive = try makeZip()
        let tree = bench.inside(archive, "tree")
        let flag = CancellationFlag()
        let writer = try bench.zip.write(tree.appending(name: "never.txt"), cancellation: flag)
        try writer.write(Data("some".utf8))
        writer.interrupt()
        #expect(throws: ArchiveError.self) { try writer.write(Data("more".utf8)) }
        #expect(throws: ArchiveError.self) { try writer.close(attributes: FileAttributes()) }
        // Nothing joined the archive, and it is not held open for a writer that is gone.
        #expect(try bench.names(tree).contains("never.txt") == false)
        #expect(try !bench.store.archive(at: archive, cancellation: nil).isBusy)
    }
}
