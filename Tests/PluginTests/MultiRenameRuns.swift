import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import MultiRenamePlugin

/// The Multi-Rename Tool driven through its command and its session, on a file system in
/// memory and on the local disk.
///
/// No window is involved.
@MainActor
@Suite
internal struct MultiRenameRuns {
    /// The file system of the panels: three pictures and a note in `/photos`, and `/other`.
    internal let memory = MemoryFileSystem()
    /// A folder on the disk, for the log and for files on the local disk.
    internal let box: Sandbox
    /// The settings of the program.
    internal let settings = MemorySettings()
    /// The tool, without windows.
    internal let plugin: MultiRenamePlugin
    /// The program the tool runs in.
    internal let bench: TestBench

    /// The answers to the tool's questions, and what it asked.
    internal var interaction: ScriptedInteraction { bench.interaction }
    /// The left panel, whose items the tool renames.
    internal var left: FakePanel { bench.left }
    /// The names in `/photos`, in order.
    internal var photos: [String] {
        memory.allPaths.filter { $0.hasPrefix("/photos/") }.map { String($0.dropFirst(8)) }
    }

    /// The bench over `/photos`, with the tool.
    internal init() throws {
        box = try Sandbox()
        for (index, name) in ["IMG_1001.jpg", "IMG_1002.jpg", "IMG_1003.jpg"].enumerated() {
            memory.addFile(
                "/photos/" + name,
                "p\(index)",
                modified: Date(timeIntervalSince1970: 1_764_583_509 + Double(index) * 86_400)
            )
        }
        memory.addFile("/photos/notes.txt", "n")
        memory.addDirectory("/other")
        plugin = MultiRenamePlugin(opensWindows: false, logDirectory: box.url("log"))
        bench = TestBench(
            plugins: [plugin],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/photos"),
            right: memory.url("/other"),
            settings: settings
        )
    }

    /// Opens the tool on all items of the left panel.
    @discardableResult
    internal func open() -> MultiRenameSession {
        open([], settingsName: nil)
    }

    /// Opens the tool on the given names of the left panel (all of them when none are given).
    @discardableResult
    internal func open(_ names: [String]) -> MultiRenameSession {
        open(names, settingsName: nil)
    }

    /// Opens the tool on the given names of the left panel (all of them when none are given) with the saved
    /// settings `settingsName`.
    @discardableResult
    internal func open(_ names: [String], settingsName: String?) -> MultiRenameSession {
        left.model.clearSelection()
        for name in names {
            left.model.select(mask: name)
        }
        if names.isEmpty {
            left.model.selectAll()
        }
        #expect(bench.commands.perform(.multiRename, settingsName.map(CommandArgument.text) ?? .nothing))
        guard let session = plugin.session else { preconditionFailure("the command opens a session") }
        return session
    }

    /// The new names of the session's rows.
    internal func names(_ session: MultiRenameSession) -> [String?] { session.rows.map(\.newName) }

    // MARK: Registration

    /// The command, its key, menus, toolbar button and preferences page; it needs a file system that can write.
    @Test
    internal func commandMenuAndPreferences() {
        #expect(bench.commands[.multiRename]?.title == "Multi-Rename Tool…")
        #expect(bench.kernel.keyBindings.command(for: Shortcut(.character("m"), .control)) == .multiRename)
        #expect(bench.kernel.menus.menus.first?.items == [.multiRename])
        #expect(bench.kernel.menus.contextMenu(onItem: true) == [.multiRename])
        #expect(bench.kernel.toolbar.defaultLayout.compactMap { $0?.command } == [.multiRename])
        #expect(bench.kernel.preferences.pages.map(\.title) == ["Multi-Rename Tool"])
        memory.capabilities = []
        #expect(!bench.commands.isEnabled(.multiRename))
    }

    /// The tool renames the marked items, or the one under the cursor when none is marked.
    @Test
    internal func operandsAreTheSelectionOrTheCursorItem() {
        #expect(open(["IMG_1002.jpg", "notes.txt"]).rows.map(\.entry.name) == ["IMG_1002.jpg", "notes.txt"])
        left.model.clearSelection()
        left.moveCursor(toName: "IMG_1003.jpg")
        bench.commands.perform(.multiRename)
        #expect(plugin.session?.rows.map(\.entry.name) == ["IMG_1003.jpg"])
    }

    // MARK: Preview

    /// The preview follows every change of the settings, and an invalid mask shows the error marker.
    @Test
    internal func previewFollowsTheSettings() {
        let session = open(["IMG_*"])
        #expect(
            names(session) == ["IMG_1001.jpg", "IMG_1002.jpg", "IMG_1003.jpg"]
                && session.rows.allSatisfy { $0.status == .unchanged }
        )
        session.settings.nameMask = "Photo_[C]_[Y]-[M]-[D]"
        session.settings.counter = CounterDefinition(start: 110, step: 15, digits: 1)
        #expect(names(session) == ["Photo_110_2025-12-01.jpg", "Photo_125_2025-12-02.jpg", "Photo_140_2025-12-03.jpg"])
        #expect(session.rows.allSatisfy { $0.status == .ready } && session.counts.changing == 3)
        session.settings.nameMask = "[P]-[G][N5-]"
        #expect(names(session).first == "photos-1001.jpg")
        session.settings.nameMask = "[Q]"
        #expect(
            names(session) == [nil, nil, nil] && session.rows.allSatisfy { $0.status == .error }
                && session.problem != nil
        )
        #expect(photos == ["IMG_1001.jpg", "IMG_1002.jpg", "IMG_1003.jpg", "notes.txt"])
    }

    /// The preview marks names taken by another item or a file, and names a file cannot have.
    @Test
    internal func previewMarksConflictsAndInvalidNames() {
        let session = open(["IMG_*"])
        session.settings.nameMask = "same"
        #expect(session.rows.allSatisfy { $0.status == .duplicate } && session.counts.conflicts == 3)
        session.settings.nameMask = "[N1-7]"
        #expect(session.rows.map(\.status) == [.duplicate, .duplicate, .duplicate])
        session.settings = RenameSettings()
        session.settings.search = "IMG_1001.jpg|IMG_1002"
        session.settings.replacement = "notes.txt|IMG_1003"
        // The first collides with a file outside the list, the second with one that stays.
        #expect(session.rows.map(\.status) == [.exists, .duplicate, .unchanged])
        session.settings = RenameSettings()
        session.settings.nameMask = ""
        session.settings.extensionMask = ""
        #expect(session.rows.allSatisfy(\.status.isInvalid) && session.counts.errors == 3)
    }

    /// A long list is previewed in the background, and of two changes the last one wins.
    @Test
    internal func previewInTheBackground() async {
        let items = (0..<3_000)
            .map { index in
                FileItem(url: memory.addFile("/many/f\(index).txt"), name: "f\(index).txt")
            }
        var renaming = RenameSettings()
        renaming.nameMask = "[N]_[C:4]"
        let session = MultiRenameSession(
            kernel: bench.kernel,
            items: items,
            store: RenameStore(settings: settings),
            settings: renaming,
            logDirectory: box.url("log"),
            previewsInBackground: true,
            clipboard: { nil },
            clipboardChangeCount: nil
        )
        var changes = 0
        session.onChange = { changes += 1 }
        // Changes that overtake each other leave the result of the last one.
        session.settings.nameMask = "[N]-[C:5]"
        session.settings.nameMask = "[N]+[C:5]"
        // The result comes back over the main queue, which this test shares with every other
        // test of the process; in a full run that alone has taken more than 20 s. The limit
        // only ends a preview that never comes.
        let deadline = Date().addingTimeInterval(600)
        while session.isComputing, Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(!session.isComputing && changes >= 1)
        #expect(session.rows.first?.newName == "f0+00001.txt" && session.rows.last?.newName == "f2999+03000.txt")
        #expect(session.rows.allSatisfy { $0.status == .ready })
    }
}
