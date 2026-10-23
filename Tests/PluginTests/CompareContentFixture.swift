import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport

@testable import CompareContentPlugin

/// Compare by content with fake panels on two folders in memory, a scripted user and jobs that run at once.
///
/// Both folders have `notes.txt` (the right one with a line changed and one added), a `twin.txt` of the same
/// content and a folder; the left one has two more files, the right one `zebra.txt`.
@MainActor
internal struct CompareContentFixture {
    /// The two folders.
    internal let memory = MemoryFileSystem()
    /// The plugin, without windows.
    internal let plugin = CompareContentPlugin(opensWindows: false)
    /// The settings of the bench.
    internal let settings = MemorySettings()
    /// The kernel with the plugin, its panels on the two folders.
    internal let bench: TestBench

    /// The scripted answers of the user, and what was asked.
    internal var interaction: ScriptedInteraction { bench.interaction }
    /// The session of the last comparison.
    internal var session: CompareSession { plugin.sessions[0] }

    /// The two folders and the bench.
    internal init() {
        memory.addFile("/A/notes.txt", "one\ntwo\nthree\nfour\n")
        memory.addFile("/B/notes.txt", "one\n2\nthree\nfour\nfive\n")
        memory.addFile("/A/other.txt", "alpha\n")
        memory.addFile("/A/third.txt", "beta\n")
        memory.addFile("/A/twin.txt", "the same\n")
        memory.addFile("/B/twin.txt", "the same\n")
        memory.addFile("/B/zebra.txt", "gamma\n")
        memory.addFile("/A/folder/inside.txt")
        memory.addFile("/B/folder/inside.txt")
        bench = TestBench(
            plugins: [plugin],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/B"),
            settings: settings
        )
    }

    /// Runs the command without an argument and returns the paths of the two files it took.
    internal func operands() -> [String?] {
        operands(.nothing)
    }

    /// Runs the command with `argument` and returns the paths of the two files it took.
    internal func operands(_ argument: CommandArgument) -> [String?] {
        bench.commands.perform(.compareByContent, argument)
        return [session.leftURL?.path, session.rightURL?.path]
    }

    /// Compares the file of that name in the left panel with its partner, after re-reading
    /// the panels for files a test has just made.
    internal func compare(_ name: String) {
        bench.left.reload()
        bench.right.reload()
        bench.left.moveCursor(toName: name)
        bench.commands.perform(.compareByContent)
    }

    /// The left and right texts of the rows, `|` between the sides.
    internal func rows() -> [String] {
        (0..<session.rowCount)
            .map { row in "\(session.text(.left, row: row) ?? "~")|\(session.text(.right, row: row) ?? "~")" }
    }
}
