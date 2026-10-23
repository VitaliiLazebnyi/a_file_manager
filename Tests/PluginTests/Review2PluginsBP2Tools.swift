import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import DirectorySyncPlugin
@testable import FileToolsPlugin

/// Review round 2, second pass: the tools.
///
/// BLAKE3 beside many files, the reproducers of the fuzzer, and a listing that the cancel cuts short, which had
/// no test.
@MainActor
@Suite
internal struct Review2PluginsBP2Tools {
    /// A folder of its own on disk for each test.
    internal let box: Sandbox
    /// The local file system.
    internal let registry = FileSystemRegistry()

    /// A fresh folder on disk, reached through the local file system.
    internal init() throws {
        box = try Sandbox()
        registry.register(LocalFileSystem())
    }

    /// The item at `path` in the folder, which must be there.
    internal func item(_ path: String) throws -> FileItem {
        try #require(registry.item(at: box.url(path)))
    }

    /// A run of a tool without a job; usable from any thread.
    nonisolated internal func run() -> ToolRun {
        ToolRun(
            fileSystems: registry,
            cancellation: CancellationFlag(),
            report: { _ in
                // Not watched here.
            },
            askExisting: { _ in .overwrite }
        )
    }

    /// A reproducer the fuzzer left; nil where the tree has no `Tests/Fuzz`.
    internal func reproducer(_ name: String) -> Data? {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try? Data(contentsOf: tests.appendingPathComponent("Fuzz/repro/tools/" + name))
    }

    // MARK: T050, BLAKE3 beside many files

    /// BLAKE3 spreads a block over the cores only while fewer files than cores are being hashed.
    @Test
    internal func blake3SpreadsOverTheCoresOnlyWhileCoresAreLeftOver() {
        #expect(
            ChecksumRun.spreadsBLAKE3(filesInProgress: 0, cores: 8)
                && ChecksumRun.spreadsBLAKE3(filesInProgress: 1, cores: 8)
        )
        #expect(ChecksumRun.spreadsBLAKE3(filesInProgress: 7, cores: 8))
        #expect(
            !ChecksumRun.spreadsBLAKE3(filesInProgress: 8, cores: 8)
                && !ChecksumRun.spreadsBLAKE3(filesInProgress: 100, cores: 8)
        )
        #expect(!ChecksumRun.spreadsBLAKE3(filesInProgress: 1, cores: 1))
    }

    /// BLAKE3 fed in small pieces gives the same digest as fed whole; other hashers are fed as they are.
    @Test
    internal func feedingBLAKE3InSmallPiecesGivesTheSameDigest() {
        // The piece is smaller than what BLAKE3 spreads over threads (16 chunks of 1 KB).
        #expect(ChecksumRun.serialPiece < 16 * 1_024)
        for size in [0, 1, 1_023, 1_024, 8_191, 8_192, 8_193, 100_000, (1 << 20) + 7, 3 << 20] {
            let block = Data((0..<size).map { index in UInt8(truncatingIfNeeded: index &* 31 &+ index >> 8) })
            let whole = BLAKE3Hasher()
            let spread = BLAKE3Hasher()
            let serial = BLAKE3Hasher()
            whole.update(block)
            ChecksumRun.feed(spread, block, spread: true)
            ChecksumRun.feed(serial, block, spread: false)
            let expected = whole.finish()
            #expect(spread.finish() == expected && serial.finish() == expected, "size \(size)")
        }
        // Other methods are never cut up; a slice of a larger Data is fed as it is.
        let big = Data(repeating: 7, count: 100_000)
        let slice = big[1_000..<60_000]
        let fed = BLAKE3Hasher()
        let copied = BLAKE3Hasher()
        ChecksumRun.feed(fed, slice, spread: false)
        copied.update(Data(slice))
        #expect(fed.finish() == copied.finish())
        let one = ChecksumMethod.sha256.makeHasher()
        let two = ChecksumMethod.sha256.makeHasher()
        ChecksumRun.feed(one, big, spread: false)
        two.update(big)
        #expect(one.finish() == two.finish())
    }

    /// Many files hashed side by side get the digests they get one by one.
    ///
    /// Off the main thread: making and hashing 40 files takes seconds, which other tests waited for when it ran
    /// there.
    @Test
    nonisolated internal func manyFilesAreHashedToTheSameDigestsAsOneByOne() throws {
        // More files than cores, and a few larger than the blocks BLAKE3 spreads.
        var files: [(url: URL, methods: [ChecksumMethod])] = []
        var expected: [[[UInt8]]] = []
        for number in 0..<40 {
            let size = number.isMultiple(of: 5) ? (3 << 20) + number : 1_000 * (number + 1)
            let data = Data((0..<size).map { index in UInt8(truncatingIfNeeded: index &* (number + 3) &+ number) })
            try data.write(to: box.url("f\(number).bin"))
            let methods: [ChecksumMethod] = number.isMultiple(of: 3) ? [.blake3, .sha256] : [.blake3]
            files.append((box.url("f\(number).bin"), methods))
            expected.append(
                methods.map { method in
                    let hasher = method.makeHasher()
                    hasher.update(data)
                    return hasher.finish()
                }
            )
        }
        let results = ChecksumRun.digests(of: files, run: run())
        for (number, result) in results.enumerated() {
            #expect(try result.get() == expected[number], "file \(number)")
        }
    }

    // MARK: The reproducers of the fuzzer

    /// The checksum file the fuzzer found with an empty name yields no entry without a name.
    @Test
    internal func theChecksumFileWithAnEmptyNameYieldsNoEntryWithoutAName() {
        guard let data = reproducer("checksum-empty-name.md5") else {
            return
        }
        let text = ChecksumFile.text(from: data)
        for name in ["a.md5", "a.sfv", "a.sha1", "a.sha256", "a.bk3", "a.sha512"] {
            let parsed = ChecksumFile.parseLines(text, fileName: name)
            #expect(parsed.entries.allSatisfy { entry in !entry.name.isEmpty }, "\(name)")
        }
        #expect(ChecksumFile.parseLines(text, fileName: "a.md5").unreadableLines == [1])
    }

    /// A stored name with a slash followed by a combining mark does not lead out of the target folder.
    @Test
    internal func aStoredNameWithASlashAndACombiningMarkDoesNotLeadOutOfTheTargetFolder() throws {
        guard let data = reproducer("combine-containment-slash-combining-mark.crc") else {
            return
        }
        try box.file("in/data.001", "abc")
        try box.file("in/data.002", "def")
        try box.folder("out/target")
        try data.write(to: box.url("in/data.crc"))
        for start in ["data.crc", "data.001"] {
            let plan = try Combiner.plan(for: item("in/" + start), run: run())
            #expect(plan.parts.map(\.name) == ["data.001", "data.002"])
            let outcome = try Combiner.combine(plan.parts, info: plan.info, into: box.url("out/target"), run: run())
            #expect(outcome.output.deletingLastPathComponent().path == box.url("out/target").path)
            #expect(try Data(contentsOf: outcome.output) == Data("abcdef".utf8))
            try FileManager.default.removeItem(at: outcome.output)
        }
        // Nothing was written beside the target folder.
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: box.url("out").path)) ?? []) == ["target"])
    }

    /// A decoded name with a slash followed by a combining mark stays in the target folder.
    @Test
    internal func aDecodedNameWithASlashAndACombiningMarkStaysInTheTargetFolder() throws {
        guard let data = reproducer("decode-containment-slash-combining-mark.bin") else {
            return
        }
        try box.folder("in")
        try box.folder("out/target")
        try data.write(to: box.url("in/part001.uue"))
        for autoRename in [false, true] {
            let written =
                (try? Decoder.decode(
                    item("in/part001.uue"),
                    into: box.url("out/target"),
                    autoRename: autoRename,
                    run: run()
                )) ?? []
            for url in written { #expect(url.deletingLastPathComponent().path == box.url("out/target").path) }
        }
        #expect(
            !((try? FileManager.default.contentsOfDirectory(atPath: box.url("out").path)) ?? [])
                .contains { name in name != "target" }
        )
    }

    /// The last word on a decoded name is the kernel's check of a safe name.
    @Test
    internal func theLastWordOnADecodedNameIsTheKernelsCheck() {
        let folder = box.url("target")
        #expect(folder.appending(safeName: "a.txt")?.lastPathComponent == "a.txt")
        for bad in ["", ".", "..", "a/b", "a\0b"] { #expect(folder.appending(safeName: bad) == nil, "\(bad)") }
    }

    // MARK: T040, a listing the cancel cut short, with the flag unset when it began

    /// A listing that the cancel ends while it runs is not taken for an empty folder, which would be deleted.
    @Test
    internal func aListingThatTheCancelEndsWhileItRunsIsNotAnEmptyFolder() {
        let memory = MemoryFileSystem()
        let stalling = FileSystemRegistry()
        stalling.register(memory)
        memory.addFile("/R/keep/inside.txt", "mine")
        memory.addFile("/R/empty/placeholder", "x")
        memory.stallsListings = true
        defer { memory.releaseStalls() }
        let flag = CancellationFlag()
        var plan = SyncPlan(rows: [])
        plan.deleteRight = [SyncPlan.Deletion(url: memory.url("/R/keep"), isDirectory: true)]
        var options = SyncRunOptions()
        options.useTrash = false
        let executor = SyncExecutor(plan: plan, options: options, fileSystems: stalling, cancellation: flag)
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            _ = executor.run()
            finished.signal()
        }
        thread.start()
        // The listing waits inside the file system (stalled); the cancel ends it quietly with nothing.
        Thread.sleep(forTimeInterval: 0.1)
        flag.cancel()
        #expect(finished.wait(timeout: .now() + Wait.ceiling) == .success)
        #expect(memory.exists("/R/keep/inside.txt") && memory.exists("/R/keep"))
    }
}
