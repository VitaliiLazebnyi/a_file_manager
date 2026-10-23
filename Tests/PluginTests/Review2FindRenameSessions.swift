import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import MultiRenamePlugin

/// Round 2 of the review, Multi-Rename sessions: a clipboard that is not read for every key, previews
/// held back while typing, sorts, names that move files, `[u]` on the disk, the undo store.
@MainActor
@Suite
internal struct Review2FindRenameSessions {
    /// The change count of the clipboard, asked on the main thread.
    @MainActor
    private final class ChangeCount {
        var value = 1

        deinit {
            // Nothing to release.
        }
    }

    /// The file system of the list: `/d` with three files, and `/other`.
    internal let memory = MemoryFileSystem()
    /// The settings of the bench and of the stores.
    internal let settings = MemorySettings()
    /// The program the sessions run in.
    internal let bench: TestBench
    /// A folder on the disk for the log and for files on the local disk.
    internal let box: Sandbox

    /// The bench over `/d` with `a.txt`, `b.txt` and `c.txt`.
    internal init() throws {
        box = try Sandbox()
        for name in ["a.txt", "b.txt", "c.txt"] {
            memory.addFile("/d/" + name, name)
        }
        memory.addDirectory("/other")
        bench = TestBench(
            plugins: [],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/d"),
            right: memory.url("/other"),
            settings: settings
        )
    }

    /// A copy of the undo settings of another store, as a program that is started again would find them.
    private static func copy(of settings: MemorySettings) -> MemorySettings {
        let copy = MemorySettings()
        for key in ["multirename.undo", "multirename.undoCount"] {
            copy.set(settings.data(forKey: key), forKey: key)
        }
        return copy
    }

    /// A session over the left panel's items that reads the clipboard with `clipboard`; previews in the
    /// background with `background`.
    internal func session(
        clipboard: @escaping @Sendable () -> String?,
        changes: (@MainActor () -> Int)?,
        background: Bool
    ) -> MultiRenameSession {
        MultiRenameSession(
            kernel: bench.kernel,
            items: bench.left.model.items,
            store: RenameStore(settings: settings),
            settings: .unchanged,
            logDirectory: box.url("log"),
            previewsInBackground: background,
            clipboard: clipboard,
            clipboardChangeCount: changes
        )
    }

    /// The clipboard is read only when a mask uses it, and again only when it changed.
    @Test
    internal func theClipboardIsReadOnlyWhenAMaskUsesItAndOnlyWhenItChanged() {
        // Used by the session's callbacks, which run one at a time while the test waits for them.
        nonisolated(unsafe) var reads = 0
        let count = ChangeCount()
        let session = session(
            clipboard: {
                reads += 1
                return "clip"
            },
            changes: { count.value },
            background: false
        )
        for mask in ["[N]a", "[N]b", "[N]c", "[N]d"] {
            session.settings.nameMask = mask
        }
        #expect(reads == 0)
        session.settings.nameMask = "[X]_[N]"
        #expect(reads == 1 && session.rows.first?.newName == "clip_a.txt")
        for mask in ["[X]1", "[X]2", "[X]3"] {
            session.settings.nameMask = mask
        }
        #expect(reads == 1)
        count.value = 2
        session.settings.nameMask = "[X]4"
        #expect(reads == 2)
    }

    /// A clipboard that does not answer leaves the preview with the error marker after a while.
    @Test
    internal func aClipboardThatDoesNotAnswerLeavesThePreviewWithTheErrorMarker() {
        let blocked = DispatchSemaphore(value: 0)
        let session = session(
            clipboard: {
                _ = blocked.wait(timeout: .now() + 5)
                return "late"
            },
            changes: { 1 },
            background: false
        )
        let start = Date()
        session.settings.nameMask = "[X]"
        // The preview waited a while for the clipboard and then went on without it.
        #expect(session.rows.allSatisfy { $0.newName == nil } && Date().timeIntervalSince(start) < 30)
        blocked.signal()
    }

    /// Changes of the fields are held back for a moment, and the last one wins.
    @Test
    internal func changesOfTheFieldsAreHeldBackForAMomentAndTheLastOneWins() async {
        let session = session(clipboard: { nil }, changes: nil, background: true)
        var changes = 0
        session.onChange = { changes += 1 }
        let base = changes
        for mask in ["[N]1", "[N]2", "[N]3", "[N]4"] {
            session.settings.nameMask = mask
        }
        // Nothing was computed for the first three.
        #expect(session.isComputing)
        let patience = Date(timeIntervalSinceNow: Wait.ceiling)
        while session.isComputing, Date() < patience {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(
            !session.isComputing && session.rows.map(\.newName) == ["a4.txt", "b4.txt", "c4.txt"] && changes - base <= 2
        )
    }

    /// Of two sorts of a long list in a row, the last one is in force.
    @Test
    internal func twoSortsInARowLeaveTheLastOneInForce() async {
        memory.removeTree("/d")
        for index in 0..<2_500 {
            memory.addFile(
                String(format: "/d/f%04d.txt", index),
                "x",
                modified: Date(timeIntervalSince1970: Double(index))
            )
        }
        bench.left.show(memory.url("/d"), focus: nil, history: .keep, completion: nil)
        let session = session(clipboard: { nil }, changes: nil, background: true)
        session.sort(by: .name, ascending: false)
        session.sort(by: .name, ascending: true)
        let patience = Date(timeIntervalSinceNow: Wait.ceiling)
        while session.isComputing, Date() < patience {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(session.rows.first?.entry.name == "f0000.txt" && session.rows.last?.entry.name == "f2499.txt")
    }

    /// Names from a list that move files into other folders are asked about first.
    @Test
    internal func namesFromAListThatMoveFilesAreAskedAbout() {
        let session = session(clipboard: { nil }, changes: nil, background: false)
        session.loadNames(fromText: "x.txt\nsub/y.txt\nz.txt")
        bench.interaction.choiceAnswers = [1]
        var result: RenameRunResult?
        session.start { result = $0 }
        #expect(result?.cancelled == true && memory.exists("/d/a.txt") && !memory.exists("/d/x.txt"))
        bench.interaction.choiceAnswers = [0]
        session.start { result = $0 }
        #expect(result?.renamed.count == 3 && memory.exists("/d/sub/y.txt"))
    }

    /// A run leaves the preview and the list as they should be: the renamed items are gone.
    @Test
    internal func aRunLeavesThePreviewAndTheListAsTheyShouldBe() {
        let session = session(clipboard: { nil }, changes: nil, background: false)
        session.settings.nameMask = "n_[N]"
        #expect(session.counts.changing == 3)
        session.start(completion: nil)
        #expect(session.rowCount == 0 && !session.isBusy && memory.exists("/d/n_a.txt"))
    }

    /// `[u]` renames a decomposed name on the local disk, and Undo writes the accent back the way it was.
    @Test
    internal func precomposingRenamesTheFileOnTheLocalDisk() throws {
        let decomposed = "e\u{301}.txt"
        try box.file("p/" + decomposed, "x")
        let local = TestBench(
            plugins: [],
            fileSystems: [LocalFileSystem()],
            left: box.url("p"),
            right: box.url("p"),
            settings: settings
        )
        let item = try #require(local.left.model.items.first)
        var request = RenameSettings()
        request.nameMask = "[u][N]"
        let session = MultiRenameSession(
            kernel: local.kernel,
            items: [item],
            store: RenameStore(settings: settings),
            settings: request,
            logDirectory: box.url("log"),
            previewsInBackground: false,
            clipboard: { nil },
            clipboardChangeCount: nil
        )
        #expect(session.rows.map(\.status) == [.ready])
        var result: RenameRunResult?
        session.start { result = $0 }
        let names = try FileManager.default.contentsOfDirectory(atPath: box.url("p").path)
            .map { name in Array(name.unicodeScalars.map(\.value)) }
        #expect(result?.failures.isEmpty == true && names == [[0xE9, 0x2E, 0x74, 0x78, 0x74]])
        // And Undo writes the accent the way it was.
        local.interaction.choiceAnswers = [0]
        session.undo(completion: nil)
        let back = try FileManager.default.contentsOfDirectory(atPath: box.url("p").path)
            .map { name in Array(name.unicodeScalars.map(\.value)) }
        #expect(back == [[0x65, 0x301, 0x2E, 0x74, 0x78, 0x74]])
    }

    /// The undo history is counted without being decoded, and is decoded when asked for.
    @Test
    internal func theUndoHistoryNeedsNoDecodingToBeCounted() async {
        let store = RenameStore(settings: settings)
        store.appendUndo([RenamedItem(from: URL(fileURLWithPath: "/d/a"), destination: URL(fileURLWithPath: "/d/b"))])
        store.flush()
        // Another store over the same settings, as at the next start of the program.
        let next = RenameStore(settings: Self.copy(of: settings))
        #expect(next.undoCount == 1)
        var loaded = false
        next.loadUndo { loaded = true }
        let patience = Date(timeIntervalSinceNow: Wait.ceiling)
        while !loaded, Date() < patience {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(loaded && next.lastUndo.count == 1)
    }

    /// A run larger than the limit is kept for this session only, and the older runs are not saved either.
    @Test
    internal func aRunLargerThanTheLimitIsKeptOnlyForThisSession() {
        let big = (0..<(RenameStore.persistedItemLimit + 5))
            .map { index in
                RenamedItem(
                    from: URL(fileURLWithPath: "/d/\(index)"),
                    destination: URL(fileURLWithPath: "/d/n\(index)")
                )
            }
        let store = RenameStore(settings: settings)
        store.appendUndo([RenamedItem(from: URL(fileURLWithPath: "/d/a"), destination: URL(fileURLWithPath: "/d/b"))])
        store.appendUndo(big)
        store.flush()
        #expect(store.undoCount == 2)
        // Nothing of it, and not the older run either, is saved: Undo would put them back in the wrong order.
        #expect(settings.value([[RenamedItem]].self, forKey: "multirename.undo")?.isEmpty == true)
    }
}
