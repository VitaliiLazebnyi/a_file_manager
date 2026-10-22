import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import CompareContentPlugin
@testable import DirectorySyncPlugin
@testable import FileToolsPlugin

/// Review round 2, second pass: the tools.
///
/// BLAKE3 beside many files, the reproducers of the fuzzer, the marks of a long selection, and the
/// two paths that had no test (a superseded background compare, a listing that the cancel cuts
/// short).
@MainActor
@Suite
struct Review2PluginsBP2Tools {
    let box: Sandbox
    let registry = FileSystemRegistry()

    init() throws {
        box = try Sandbox()
        registry.register(LocalFileSystem())
    }

    func item(_ path: String) throws -> FileItem {
        try #require(registry.item(at: box.url(path)))
    }

    nonisolated func run() -> ToolRun {
        ToolRun(
            fileSystems: registry,
            cancellation: CancellationFlag(),
            report: { _ in },
            askExisting: { _ in .overwrite }
        )
    }

    /// A reproducer the fuzzer left; nil where the tree has no `Tests/Fuzz`.
    func reproducer(_ name: String) -> Data? {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try? Data(contentsOf: tests.appendingPathComponent("Fuzz/repro/tools/" + name))
    }

    func waitOnMain(_ seconds: Double = Wait.ceiling, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 3_000_000) }
        return condition()
    }

    // MARK: T050, BLAKE3 beside many files

    @Test
    func blake3SpreadsOverTheCoresOnlyWhileCoresAreLeftOver() {
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

    @Test
    func feedingBLAKE3InSmallPiecesGivesTheSameDigest() {
        // The piece is smaller than what BLAKE3 spreads over threads (16 chunks of 1 KB).
        #expect(ChecksumRun.serialPiece < 16 * 1_024)
        for size in [0, 1, 1_023, 1_024, 8_191, 8_192, 8_193, 100_000, (1 << 20) + 7, 3 << 20] {
            let block = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) })
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
        let a = BLAKE3Hasher()
        let b = BLAKE3Hasher()
        ChecksumRun.feed(a, slice, spread: false)
        b.update(Data(slice))
        #expect(a.finish() == b.finish())
        let one = ChecksumMethod.sha256.makeHasher()
        let two = ChecksumMethod.sha256.makeHasher()
        ChecksumRun.feed(one, big, spread: false)
        two.update(big)
        #expect(one.finish() == two.finish())
    }

    /// Off the main thread: making and hashing 40 files takes seconds, which other tests waited for when it ran there.
    @Test
    nonisolated func manyFilesAreHashedToTheSameDigestsAsOneByOne() throws {
        // More files than cores, and a few larger than the blocks BLAKE3 spreads.
        var files: [(url: URL, methods: [ChecksumMethod])] = []
        var expected: [[[UInt8]]] = []
        for number in 0..<40 {
            let size = number % 5 == 0 ? (3 << 20) + number : 1_000 * (number + 1)
            let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* (number + 3) &+ number) })
            try data.write(to: box.url("f\(number).bin"))
            let methods: [ChecksumMethod] = number % 3 == 0 ? [.blake3, .sha256] : [.blake3]
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

    @Test
    func theChecksumFileWithAnEmptyNameYieldsNoEntryWithoutAName() {
        guard let data = reproducer("checksum-empty-name.md5") else {
            return
        }
        let text = ChecksumFile.text(from: data)
        for name in ["a.md5", "a.sfv", "a.sha1", "a.sha256", "a.bk3", "a.sha512"] {
            let parsed = ChecksumFile.parseLines(text, fileName: name)
            #expect(parsed.entries.allSatisfy { !$0.name.isEmpty }, "\(name)")
        }
        #expect(ChecksumFile.parseLines(text, fileName: "a.md5").unreadableLines == [1])
    }

    @Test
    func aStoredNameWithASlashAndACombiningMarkDoesNotLeadOutOfTheTargetFolder() throws {
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

    @Test
    func aDecodedNameWithASlashAndACombiningMarkStaysInTheTargetFolder() throws {
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
            ((try? FileManager.default.contentsOfDirectory(atPath: box.url("out").path)) ?? [])
                .filter {
                    $0 != "target"
                }
                .isEmpty
        )
    }

    @Test
    func theLastWordOnADecodedNameIsTheKernelsCheck() {
        let folder = box.url("target")
        #expect(folder.appending(safeName: "a.txt")?.lastPathComponent == "a.txt")
        for bad in ["", ".", "..", "a/b", "a\0b"] { #expect(folder.appending(safeName: bad) == nil, "\(bad)") }
    }

    // MARK: T029, a compare that was superseded and then cancelled

    @Test
    func aCancelledCompareOverEditedContentLeavesRowsThatMatchTheTexts() async throws {
        let lines = (1...3_000).map { "line \($0)" }
        try box.file("A/big.txt", lines.joined(separator: "\n") + "\n")
        try box.file(
            "B/big.txt",
            lines.map { $0.hasSuffix("7") ? $0 + " changed" : $0 }.joined(separator: "\n") + "\n"
        )
        let plugin = CompareContentPlugin(opensWindows: false)
        let bench = TestBench(
            plugins: [plugin],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B"),
            settings: MemorySettings()
        )
        bench.left.reload()
        bench.left.moveCursor(toName: "big.txt")
        bench.commands.perform(.compareByContent)
        let session = try #require(plugin.sessions.first)
        session.setEditing(true)
        #expect(session.phase == .ready && session.rowCount >= 3_000)
        // From here on the work runs on the background thread, as it does in the window.
        session.runsInline = false
        // An edit of a large text: the rows are made again in the background.
        session.setText("edited line", .left, row: 4)
        #expect(session.phase == .working)
        // Compare again (it takes the place of that), and then Esc.
        session.compare()
        session.cancel()
        #expect(await waitOnMain { session.phase == .ready })
        // The rows and the texts agree: the edit is there, and copying a row neither traps nor takes another line.
        #expect(session.text(.left, row: 4) == "edited line")
        session.copy(rows: 4..<5, to: .right)
        #expect(session.text(.right, row: 4) == "edited line")
        #expect(await waitOnMain { session.phase == .ready })
        #expect(session.text(.right, row: 5) == "line 6" || session.text(.right, row: 5) == "line 6 changed")
        session.cancel()
    }

    // MARK: T040, a listing the cancel cut short, with the flag unset when it began

    @Test
    func aListingThatTheCancelEndsWhileItRunsIsNotAnEmptyFolder() {
        let memory = MemoryFileSystem()
        let registry = FileSystemRegistry()
        registry.register(memory)
        memory.addFile("/R/keep/inside.txt", "mine")
        memory.addFile("/R/empty/placeholder", "x")
        memory.stallsListings = true
        defer { memory.releaseStalls() }
        let flag = CancellationFlag()
        var plan = SyncPlan(rows: [])
        plan.deleteRight = [SyncPlan.Deletion(url: memory.url("/R/keep"), isDirectory: true)]
        let executor = SyncExecutor(
            plan: plan,
            options: {
                var o = SyncRunOptions()
                o.useTrash = false
                return o
            }(),
            fileSystems: registry,
            cancellation: flag
        )
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

    // MARK: R024, the marks of a long selection

    func benchOf(_ memory: MemoryFileSystem, plugins: [any Plugin] = []) -> TestBench {
        TestBench(
            plugins: plugins,
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/B"),
            settings: MemorySettings()
        )
    }

    @Test
    func theNamesToSynchronizeAreReadFromTheMarksOnly() async {
        let memory = MemoryFileSystem()
        for name in ["b.txt", "a.txt", "c.txt"] { memory.addFile("/A/" + name, name) }
        for name in ["z.txt", "a.txt"] { memory.addFile("/B/" + name, name) }
        memory.addDirectory("/A/sub")
        let bench = benchOf(memory)
        let session = SyncSession(kernel: bench.kernel)
        // Nothing marked: no names.
        session.adopt(left: bench.left.model, right: bench.right.model, includeHidden: false)
        #expect(session.selectedNames.isEmpty)
        // Marked on both sides: the names of both, in order, the twin of a name once for each side.
        bench.left.model.setSelected(true, names: ["c.txt", "a.txt", "sub"])
        bench.right.model.setSelected(true, names: ["a.txt"])
        session.adopt(left: bench.left.model, right: bench.right.model, includeHidden: false)
        #expect(session.selectedNames == ["a.txt", "a.txt", "c.txt", "sub"])
        // A long selection is read in the background and arrives later, once.
        var changes = 0
        session.onChange = { changes += 1 }
        session.adopt(left: bench.left.model, right: bench.right.model, includeHidden: false, readsInBackgroundFrom: 2)
        #expect(session.selectedNames.isEmpty)
        #expect(await waitOnMain { session.selectedNames == ["a.txt", "a.txt", "c.txt", "sub"] })
        #expect(changes >= 1)
    }

    @Test
    func aSelectionReadInTheBackgroundIsDroppedWhenAnotherWindowIsOpened() async {
        let memory = MemoryFileSystem()
        for name in ["a", "b", "c", "d"] { memory.addFile("/A/" + name, name) }
        memory.addDirectory("/B")
        let bench = benchOf(memory)
        let session = SyncSession(kernel: bench.kernel)
        bench.left.model.setSelected(true, names: ["a", "b", "c"])
        session.adopt(left: bench.left.model, right: bench.right.model, includeHidden: false, readsInBackgroundFrom: 1)
        // Before that has come back, the panels are adopted again with nothing marked.
        bench.left.model.clearSelection()
        session.adopt(left: bench.left.model, right: bench.right.model, includeHidden: false, readsInBackgroundFrom: 1)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(session.selectedNames.isEmpty)
    }

    @Test
    func theFilesToCompareAreFoundWithoutLookingAtEveryMark() {
        let memory = MemoryFileSystem()
        for number in 0..<3_000 { memory.addFile(String(format: "/A/f%04d.txt", number), "x") }
        memory.addDirectory("/A/dir")
        memory.addFile("/B/f0001.txt", "y")
        memory.addFile("/B/other.txt", "z")
        let bench = benchOf(memory)
        let (source, target) = (bench.left.model, bench.right.model)
        // Nothing marked: the file under the cursor and the one of its name on the other side.
        source.moveCursor(to: source.row(ofName: "f0001.txt") ?? 0)
        var chosen = CompareOperands.choose(source: source, target: target)
        #expect(chosen.left?.lastPathComponent == "f0001.txt" && chosen.right?.lastPathComponent == "f0001.txt")
        // Everything marked (folders too): the first two files in the order of the list.
        source.selectAll()
        chosen = CompareOperands.choose(source: source, target: target)
        #expect(chosen.left?.lastPathComponent == source.items.first { !$0.isDirectory }?.name)
        #expect(chosen.right?.lastPathComponent == source.items.filter { !$0.isDirectory }[1].name)
        // One marked file: the first marked one of the other panel, otherwise the one of the same name.
        source.clearSelection()
        source.setSelected(true, names: ["f0001.txt"])
        chosen = CompareOperands.choose(source: source, target: target)
        #expect(chosen.right?.lastPathComponent == "f0001.txt")
        target.setSelected(true, names: ["other.txt"])
        chosen = CompareOperands.choose(source: source, target: target)
        #expect(chosen.left?.lastPathComponent == "f0001.txt" && chosen.right?.lastPathComponent == "other.txt")
        // Only a folder marked: the marks hold no file, the cursor's file is taken.
        source.clearSelection()
        target.clearSelection()
        source.setSelected(true, names: ["dir"])
        source.moveCursor(to: source.row(ofName: "f0002.txt") ?? 0)
        chosen = CompareOperands.choose(source: source, target: target)
        #expect(chosen.left?.lastPathComponent == "f0002.txt" && chosen.right == nil)
    }
}
