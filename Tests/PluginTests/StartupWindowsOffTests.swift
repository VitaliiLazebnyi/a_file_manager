import AFMContracts
import AFMKernel
import AppKit
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FindFilesPlugin
@testable import PlacesPlugin

/// The tools made for the tests of the whole program (`StandardPlugins.make(launchesApplications: false)`)
/// make their windows but never put them on screen.
@MainActor
@Suite(.serialized)
internal struct StartupWindowsOffTests {
    /// The panels' folders.
    private let memory = MemoryFileSystem()

    /// A folder with a file and a subfolder.
    internal init() {
        _ = NSApplication.shared
        memory.addFile("/A/one.txt")
        memory.addDirectory("/A/docs")
    }

    /// The Directory Tree window of a Places plugin without windows is made, and stays off screen.
    @Test
    internal func theDirectoryTreeIsMadeButNotShown() {
        let plugin = PlacesPlugin(keepsTreesOnDisk: false, favorites: [], opensWindows: false)
        let bench = TestBench(plugins: [plugin], fileSystems: [memory], left: memory.url("/A"), right: memory.url("/A"))
        defer {
            plugin.stop()
            plugin.treeWindow?.close()
        }
        #expect(bench.commands.perform(.directoryTree))
        #expect(plugin.treeWindow != nil && plugin.treeWindow?.window?.isVisible == false)
    }

    /// The Find Files window of a plugin without windows is made, and stays off screen.
    @Test
    internal func findFilesIsMadeButNotShown() {
        let plugin = FindFilesPlugin(opensWindows: false)
        let bench = TestBench(
            plugins: [plugin],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/A")
        )
        defer { plugin.stop() }
        #expect(bench.commands.perform(.searchFor))
        let window = plugin.mainWindow(in: bench.kernel).window
        defer { window?.close() }
        #expect(window != nil && window?.isVisible == false)
    }
}
