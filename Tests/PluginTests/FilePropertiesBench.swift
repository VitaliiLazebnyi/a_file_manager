import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport

@testable import FilePropertiesPlugin

/// A kernel with the file-properties plugin and fake panels: the left one on folder `A` of a
/// sandbox, the right one on `B`, and a file system in memory beside them.
@MainActor
internal struct FilePropertiesBench {
    /// The file system in memory: `/M/a.txt` and `/M/sub/b.txt`.
    internal let memory = MemoryFileSystem()
    /// The plugin under test; it asks no application to start.
    internal let plugin = FilePropertiesPlugin(launchesApplications: false)
    /// The kernel and its panels.
    internal let bench: TestBench
    /// `A` with two files and a folder tree, `B` with one old file.
    internal let box: Sandbox

    /// The kernel's commands.
    internal var commands: CommandRegistry { bench.commands }
    /// The panel on `A`.
    internal var left: FakePanel { bench.left }
    /// The panel on `B`.
    internal var right: FakePanel { bench.right }
    /// The dialogs and messages, answered by script.
    internal var dialogs: ScriptedInteraction { bench.interaction }

    /// The sandbox, the memory files and the kernel.
    internal init() throws {
        box = try Sandbox()
        try box.file("A/one.txt", "12345")
        try box.file("A/two.txt", "2")
        try box.file("A/docs/in.txt", "inside")
        try box.file("A/docs/deep/more.txt", "more")
        try box.file("B/other.txt", "other", modified: Date(timeIntervalSince1970: 86_400 * 365))
        memory.addFile("/M/a.txt", "abc")
        memory.addFile("/M/sub/b.txt", "defgh")
        bench = TestBench(
            plugins: [plugin],
            fileSystems: [LocalFileSystem(), memory],
            left: box.url("A"),
            right: box.url("B")
        )
    }

    /// The BSD flags of a file in the sandbox.
    internal func flags(_ path: String) -> UInt32 { LocalInfo.details(box.url(path))?.flags ?? 0 }

    /// The permissions of a file in the sandbox.
    internal func mode(_ path: String) -> UInt16 { LocalInfo.details(box.url(path))?.mode ?? 0 }

    /// The labels of a form's fields: the rows of a properties dialog.
    internal func notes(_ form: [FormField]) -> [String] { form.map(\.label) }
}
