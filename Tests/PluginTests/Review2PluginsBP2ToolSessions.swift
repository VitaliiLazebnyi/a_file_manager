import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import CompareContentPlugin
@testable import DirectorySyncPlugin

/// Review round 2, second pass: the sessions of the tools.
///
/// The marks of a long selection, and a compare in the background that was superseded and then cancelled,
/// which had no test.
@MainActor
@Suite
internal struct Review2PluginsBP2ToolSessions {
    /// A folder of its own on disk for each test.
    internal let box: Sandbox

    /// A fresh folder on disk.
    internal init() throws {
        box = try Sandbox()
    }

    /// Waits on the main thread, at most `Wait.ceiling` seconds, until `condition` holds; whether it does.
    internal func waitOnMain(until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(Wait.ceiling)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
        return condition()
    }

    /// A kernel without plugins whose panels show `/A` and `/B` of `memory`.
    internal func benchOf(_ memory: MemoryFileSystem) -> TestBench {
        TestBench(
            plugins: [],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/B"),
            settings: MemorySettings()
        )
    }

    // MARK: T029, a compare that was superseded and then cancelled

    /// A compare over edited texts that was superseded and then cancelled leaves rows that match the texts.
    @Test
    internal func aCancelledCompareOverEditedContentLeavesRowsThatMatchTheTexts() async throws {
        let lines = (1...3_000).map { number in "line \(number)" }
        try box.file("A/big.txt", lines.joined(separator: "\n") + "\n")
        try box.file(
            "B/big.txt",
            lines.map { line in line.hasSuffix("7") ? line + " changed" : line }.joined(separator: "\n") + "\n"
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

    // MARK: R024, the marks of a long selection

    /// The names to synchronize are read from the marks alone, a long selection in the background.
    @Test
    internal func theNamesToSynchronizeAreReadFromTheMarksOnly() async {
        let memory = MemoryFileSystem()
        for name in ["b.txt", "a.txt", "c.txt"] {
            memory.addFile("/A/" + name, name)
        }
        for name in ["z.txt", "a.txt"] {
            memory.addFile("/B/" + name, name)
        }
        memory.addDirectory("/A/sub")
        let bench = benchOf(memory)
        let session = SyncSession(kernel: bench.kernel)
        let (left, right) = (bench.left.model, bench.right.model)
        // Nothing marked: no names.
        session.adopt(left: left, right: right, includeHidden: false, readsInBackgroundFrom: SyncSession.backgroundFrom)
        #expect(session.selectedNames.isEmpty)
        // Marked on both sides: the names of both, in order, the twin of a name once for each side.
        bench.left.model.setSelected(true, names: ["c.txt", "a.txt", "sub"])
        bench.right.model.setSelected(true, names: ["a.txt"])
        session.adopt(left: left, right: right, includeHidden: false, readsInBackgroundFrom: SyncSession.backgroundFrom)
        #expect(session.selectedNames == ["a.txt", "a.txt", "c.txt", "sub"])
        // A long selection is read in the background and arrives later, once.
        var changes = 0
        session.onChange = { changes += 1 }
        session.adopt(left: left, right: right, includeHidden: false, readsInBackgroundFrom: 2)
        #expect(session.selectedNames.isEmpty)
        #expect(await waitOnMain { session.selectedNames == ["a.txt", "a.txt", "c.txt", "sub"] })
        #expect(changes >= 1)
    }

    /// A selection still read in the background is dropped when the panels are adopted again.
    @Test
    internal func aSelectionReadInTheBackgroundIsDroppedWhenAnotherWindowIsOpened() async {
        let memory = MemoryFileSystem()
        for name in ["a", "b", "c", "d"] {
            memory.addFile("/A/" + name, name)
        }
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

    /// The files to compare are found from the first marks, without a pass over every mark.
    @Test
    internal func theFilesToCompareAreFoundWithoutLookingAtEveryMark() {
        let memory = MemoryFileSystem()
        for number in 0..<3_000 {
            memory.addFile(String(format: "/A/f%04d.txt", number), "x")
        }
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
        #expect(chosen.left?.lastPathComponent == source.items.first { item in !item.isDirectory }?.name)
        #expect(chosen.right?.lastPathComponent == source.items.filter { item in !item.isDirectory }[1].name)
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
