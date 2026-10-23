import AFMContracts
import AFMKernel
import FileOperationsPlugin
import Foundation
import LocalFileSystemPlugin
import MacIntegrationPlugin
import NavigationPlugin
import TestSupport
import Testing

@testable import ArchivesPlugin

/// The archives plugin with the plugins it cooperates with (navigation, Mac integration, file operations), in
/// panels without a window, a scripted user and jobs that run at once.
///
/// The left panel shows `A`, with a tree (a text, a folder with two files, an empty folder), two texts and
/// `tree.zip` of the tree made by the system's zip; the right panel shows the empty `B`.
@MainActor
internal struct ArchivePanelsFixture {
    /// The sandbox that holds `A` and `B`.
    internal let box: Sandbox
    /// Another file system, in memory, for archives that do not lie on the disk.
    internal let memory = MemoryFileSystem()
    /// The Mac integration, which notes the files it would open instead of opening them.
    internal let mac = MacIntegrationPlugin(launchesApplications: false)
    /// The plugin under test; changes wait for a flush, never for a timer.
    internal let archives = ArchivesPlugin(flushDelay: nil, launchesApplications: false)
    /// The settings of the bench.
    internal let settings = MemorySettings()
    /// The kernel with the plugins and the two panels.
    internal let bench: TestBench

    /// The commands of the kernel.
    internal var commands: CommandRegistry { bench.commands }
    /// The left panel, on `A` at the start.
    internal var left: FakePanel { bench.left }
    /// The right panel, on `B` at the start.
    internal var right: FakePanel { bench.right }
    /// The scripted answers of the user, and what was asked.
    internal var interaction: ScriptedInteraction { bench.interaction }

    /// The two folders, the ZIP of the tree and the bench.
    internal init() throws {
        box = try Sandbox()
        try box.file(
            "A/tree/readme.txt",
            String(repeating: "All work and no play makes Jack a dull boy.\n", count: 400)
        )
        try box.file("A/tree/sub/inner.txt", "inner")
        try box.file("A/tree/sub/data.bin", String(repeating: "0123456789", count: 30_000))
        try box.folder("A/tree/hollow")
        try box.file("A/notes.txt", "notes")
        try box.file("A/todo.txt", "todo")
        try box.folder("B")
        #expect(runTool("/usr/bin/zip", ["-qr", "tree.zip", "tree"], in: box.url("A")).status == 0)
        bench = TestBench(
            plugins: [NavigationPlugin(), mac, FileOperationsPlugin(), archives],
            fileSystems: [LocalFileSystem(), memory],
            left: box.url("A"),
            right: box.url("B"),
            settings: settings
        )
    }

    /// Enter on an item of the left panel.
    internal func enter(_ name: String) {
        enter(name, in: left)
    }

    /// Enter on an item of `panel`, which gets the focus first.
    internal func enter(_ name: String, in panel: FakePanel) {
        panel.focus()
        panel.moveCursor(toName: name)
        commands.perform(.open)
    }

    /// The member names of the ZIP at `path` in the sandbox, as the system's unzip lists them, sorted.
    internal func unzipList(_ path: String) -> [String] {
        runTool("/usr/bin/unzip", ["-Z1", box.url(path).path], in: nil)
            .output
            .split(separator: "\n")
            .map(String.init)
            .sorted()
    }

    /// Whether the system's unzip finds the ZIP at `path` in the sandbox sound.
    internal func isSound(_ path: String) -> Bool {
        runTool("/usr/bin/unzip", ["-tq", box.url(path).path], in: nil).status == 0
    }
}
