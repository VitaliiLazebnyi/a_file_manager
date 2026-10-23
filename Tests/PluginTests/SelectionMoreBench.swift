import AFMContracts
import AFMKernel
import AppKit
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import SelectionPlugin

/// What the suites of the Mark commands share: fake panels on two folders of an in-memory file
/// system, a pasteboard and settings of their own.
@MainActor
internal protocol SelectionMoreBench {
    /// The file system the panels show, filled by `fill`.
    var memory: MemoryFileSystem { get }
    /// The clipboard the plugin reads.
    var pasteboard: NSPasteboard { get }
    /// The settings the plugin keeps its masks, types and options in.
    var settings: MemorySettings { get }
}

/// The folders, the kernel and the reading of files the suites share.
extension SelectionMoreBench {
    /// The command names of the plugin.
    internal typealias Ids = SelectionCommands

    /// Fills `/A` and `/B`: files that are newer, older, of another size or on one side only.
    internal static func fill(_ memory: MemoryFileSystem) {
        let (old, new) = (Date(timeIntervalSince1970: 1_000_000), Date(timeIntervalSince1970: 2_000_000))
        memory.addFile("/A/docs/in.txt")
        memory.addDirectory("/A/shared")
        memory.addFile("/A/one.txt", "new", modified: new)
        memory.addFile("/A/two.txt", "2", modified: old)
        memory.addFile("/A/two.md", "2", modified: old)
        memory.addFile("/A/three.md", "333", modified: old)
        memory.addFile("/A/big.bin", String(repeating: "x", count: 4_096), modified: old)
        memory.addDirectory("/B/shared")
        memory.addDirectory("/B/extra")
        memory.addFile("/B/one.txt", "old", modified: old)
        memory.addFile("/B/two.txt", "2", modified: old)
        memory.addFile("/B/three.md", "3", modified: old)
        memory.addFile("/B/only_b.txt", "b", modified: old)
    }

    /// A kernel with the plugin, working on the calling thread, and the panels on `/A` and `/B`.
    internal func makeBench() -> TestBench {
        TestBench(
            plugins: [SelectionPlugin(pasteboard: pasteboard, background: false)],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/B"),
            settings: settings
        )
    }

    /// The bytes of a file of `memory`; empty when there is none.
    internal func data(_ path: String) -> Data {
        guard let reader = try? memory.read(memory.url(path)) else {
            return Data()
        }
        return (try? reader.read(upToCount: 1 << 20)) ?? Data()
    }
}
