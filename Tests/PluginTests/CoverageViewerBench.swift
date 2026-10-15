import AFMKernel
import AFMShell
import AppKit
import LocalFileSystemPlugin
import TestSupport

@testable import ViewerPlugin

/// The viewer started in a kernel with fake panels: a memory file system with a few files in
/// `/A` (the left panel) and `/B` (the right panel), the local disk, and Lister windows that are
/// not put on screen unless asked for.
@MainActor
internal final class CoverageViewerBench {
    /// The files of the panels.
    internal let memory = MemoryFileSystem()
    /// The kernel and the panels.
    internal let bench: TestBench
    /// The viewer.
    internal let plugin: ViewerPlugin
    /// What the quick view covers in the right panel.
    internal let rightHost = CoverageViewerOverlayHost()

    /// The kernel's commands.
    internal var commands: CommandRegistry { bench.commands }

    /// The kernel's answers to questions.
    internal var interaction: ScriptedInteraction { bench.interaction }

    /// A bench whose left panel shows `/A` of the memory file system, without windows on screen.
    internal convenience init() {
        self.init(left: nil, showsWindows: false)
    }

    /// A bench whose left panel shows `left` (`/A` of the memory file system when nil).
    internal init(left: URL?, showsWindows: Bool) {
        _ = NSApplication.shared
        memory.addFile("/A/notes.txt", "First line\nSecond line\nThird line")
        memory.addFile("/A/other.txt", "Another file")
        memory.addFile("/A/folder/inside.txt", "inside")
        memory.addFile("/B/right.txt", "right")
        let host = rightHost
        let lookup = CoverageViewerHostLookup()
        plugin = ViewerPlugin(overlayHost: { lookup.host(for: $0) }, quickViewDelay: 0.01, showsWindows: showsWindows)
        // No test plays a sound: the player only records.
        plugin.mediaPlayback = CovViewPlayback.factory
        bench = TestBench(
            plugins: [plugin],
            fileSystems: [memory, LocalFileSystem()],
            left: left ?? memory.url("/A"),
            right: memory.url("/B")
        )
        lookup.right = bench.right
        lookup.rightHost = host
    }

    /// Waits until `condition` holds, letting the main queue run meanwhile; false only after a
    /// hang (`Wait.ceiling`: on a busy machine a minute is not enough).
    internal func wait(until condition: () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: Wait.ceiling)
        while !condition() {
            if Date() > deadline {
                return false
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return true
    }

    deinit {
        // Nothing to release.
    }
}
