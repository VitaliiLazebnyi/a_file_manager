import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import MultiRenamePlugin

/// The tool opened through its command with a window, as the program opens it.
@MainActor
@Suite(.serialized)
internal struct CoverageRenamePluginWindow {
    /// The file system of the panel: two files in `/p`.
    internal let memory = MemoryFileSystem()
    /// A folder on the disk for the log.
    internal let box: Sandbox
    /// The tool, with windows.
    internal let plugin: MultiRenamePlugin
    /// The program the tool runs in.
    internal let bench: TestBench
    /// The windows the tool was asked to show: none is put on screen.
    internal let presenter = StabilityPresenter()

    /// The windows of the tool that are open.
    internal var windows: [NSWindow] { presenter.open.filter { $0.title == "Multi-Rename Tool" } }

    /// The tool over `/p`, its windows shown to nobody.
    internal init() throws {
        _ = NSApplication.shared
        box = try Sandbox()
        memory.addFile("/p/a.txt")
        memory.addFile("/p/b.txt")
        plugin = MultiRenamePlugin(logDirectory: box.url("log"))
        plugin.present = presenter.present
        bench = TestBench(plugins: [plugin], fileSystems: [memory], left: memory.url("/p"), right: memory.url("/p"))
    }

    /// Opening the tool again replaces its window, and closing it keeps the settings for the next time.
    @Test
    internal func openingAgainReplacesTheWindowAndClosingKeepsTheSettings() async {
        defer {
            plugin.stop()
            presenter.closeAll()
        }
        bench.left.model.selectAll()
        #expect(bench.commands.perform(.multiRename))
        let first = plugin.session
        #expect(windows.count == 1)
        first?.settings.nameMask = "o[C]"
        #expect(bench.commands.perform(.multiRename))
        #expect(windows.count == 1 && plugin.session !== first && plugin.session?.settings.nameMask == "o[C]")
        // The clipboard is read when a mask asks for it.
        plugin.session?.settings.nameMask = "[X+]c"
        #expect(await RunLoopWait.until { plugin.session?.isComputing == false })
        // As the close button does, without `performClose`, which runs the event loop for a moment.
        if let window = windows.first, window.delegate?.windowShouldClose?(window) ?? true {
            window.close()
        }
        #expect(plugin.session == nil && windows.isEmpty)
        #expect(bench.commands.perform(.multiRename))
        #expect(plugin.session?.settings.nameMask == "[X+]c")
        plugin.stop()
        #expect(windows.isEmpty)
        // Stopped again, with nothing open, nothing happens.
        plugin.stop()
    }
}
