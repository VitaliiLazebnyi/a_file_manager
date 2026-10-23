import AFMContracts
import AFMKernel
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import MultiRenamePlugin

/// Undo that cannot finish, and sorting, through a session on a file system in memory.
@MainActor
@Suite
internal struct MultiRenameFixSessions {
    /// The memory the files are in, in `/d`.
    internal let memory = MemoryFileSystem()
    /// The settings the store keeps its values in.
    internal let settings = MemorySettings()
    /// The tool, without windows.
    internal let plugin: MultiRenamePlugin
    /// The kernel with the tool, the left panel in `/d`.
    internal let bench: TestBench
    /// A folder of the test's own on the local disk, for the log.
    internal let box: Sandbox

    /// Four files in `/d` of the memory and the tool in a kernel.
    internal init() throws {
        box = try Sandbox()
        for name in ["b.txt", "a.jpg", "c.txt", "a.txt"] {
            memory.addFile("/d/" + name, name)
        }
        memory.addDirectory("/other")
        plugin = MultiRenamePlugin(opensWindows: false, logDirectory: box.url("log"))
        bench = TestBench(
            plugins: [plugin],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/d"),
            right: memory.url("/other"),
            settings: settings
        )
    }

    /// The tool opened on the files of the left panel that match `pattern`.
    internal func open(_ pattern: String) throws -> MultiRenameSession {
        bench.left.model.clearSelection()
        bench.left.model.select(mask: pattern)
        #expect(bench.commands.perform(.multiRename))
        return try #require(plugin.session)
    }

    /// Sorting by extension keeps equal items in their order, in both directions.
    @Test
    internal func sortingByExtensionKeepsEqualItemsInOrder() throws {
        let session = try open("*")
        session.sort(by: .ext, ascending: true)
        #expect(session.rows.map(\.entry.name) == ["a.jpg", "a.txt", "b.txt", "c.txt"])
        session.sort(by: .ext, ascending: false)
        #expect(session.rows.map(\.entry.name) == ["c.txt", "b.txt", "a.txt", "a.jpg"])
        session.sort(by: .name, ascending: true)
        #expect(session.rows.map(\.entry.name) == ["a.jpg", "a.txt", "b.txt", "c.txt"])
    }

    /// A run that can never be undone does not block the earlier ones.
    @Test
    internal func aRunThatCanNeverBeUndoneDoesNotBlockEarlierOnes() throws {
        var session = try open("a.*")
        session.settings.nameMask = "first[C]"
        session.start(completion: nil)
        session = try open("c.txt")
        session.settings.nameMask = "second"
        session.start(completion: nil)
        #expect(RenameStore(settings: settings).undoCount == 2)
        // The file of the newer run is deleted by somebody else: that run cannot be taken back.
        try? memory.remove(memory.url("/d/second.txt"))
        bench.interaction.choiceAnswers = [0, 0]
        session = try open("*")
        var left: [RenamedItem] = []
        session.undo { left = $0 }
        #expect(left.count == 1 && session.canUndo)
        #expect(RenameStore(settings: settings).undoCount == 1)
        session.undo(completion: nil)
        #expect(!session.canUndo && memory.exists("/d/a.jpg") && memory.exists("/d/a.txt"))
    }
}
