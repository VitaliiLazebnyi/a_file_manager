import AFMContracts
import AFMKernel
import AppKit
import StandardPlugins
import TestSupport

@testable import AFMShell

/// The folders, the settings and the stand-ins of a test that starts the real program.
///
/// The left panel starts in `A`, the right one in `B`, a panel without a folder in `home`.
@MainActor
internal final class AppFixture {
    /// The files of the tests of the whole program: `one.txt` in both panels, newer on the left.
    internal static let programFiles = [
        "A/one.txt": "new", "A/two.txt": "2", "A/docs/in.txt": "inside", "B/one.txt": "old"
    ]
    /// The files of the tests of the window around the panels.
    internal static let windowFiles = [
        "A/one.txt": "1", "A/two words.txt": "2", "A/docs/in.txt": "inside", "B/other.txt": "o"
    ]

    /// The folders on disk.
    internal let box: Sandbox
    /// A file system in memory, registered when the whole program is started.
    internal let memory = MemoryFileSystem()
    /// The user, as the test scripts them.
    internal let user = ScriptedInteraction()
    /// The settings the program keeps.
    internal let settings = MemorySettings()
    /// A pasteboard of the test's own.
    internal let scratch = ScratchPasteboard()

    /// A sandbox with `files` (path and content), the panels set to `A` and `B`.
    internal init(files: [String: String]) throws {
        _ = NSApplication.shared
        box = try Sandbox()
        for (path, content) in files {
            try box.file(path, content)
        }
        try box.file("home/welcome.txt")
        settings.set(PanelTabs.State(tabs: [.init(location: box.url("A"))], active: 0), forKey: "left.tabs")
        settings.set(PanelTabs.State(tabs: [.init(location: box.url("B"))], active: 0), forKey: "right.tabs")
    }

    /// The whole program: the memory file system and every standard plugin.
    internal func startProgram() async -> AppRun {
        let kernel = Kernel(productName: StandardPlugins.productName, settings: settings, interaction: user)
        kernel.fileSystems.register(memory)
        kernel.load(StandardPlugins.make(pasteboard: scratch.pasteboard, launchesApplications: false))
        return await start(kernel)
    }

    /// The program with only the plugins a file manager cannot do without, and `plugin`.
    internal func startWindow(with plugin: any Plugin) async -> AppRun {
        let kernel = Kernel(productName: StandardPlugins.productName, settings: settings, interaction: user)
        kernel.load(CorePlugins.make(pasteboard: scratch.pasteboard) + [plugin])
        return await start(kernel)
    }

    /// The names in the folder `folder` of the sandbox, in order.
    internal func namesOnDisk(_ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: box.url(folder).path)) ?? []).sorted()
    }

    /// The window shell around `kernel`, once its panels have been read.
    private func start(_ kernel: Kernel) async -> AppRun {
        let running = AppRun(kernel: kernel, shell: Shell(kernel: kernel, home: box.url("home")))
        await running.settle()
        return running
    }

    deinit {
        // Nothing to release: the sandbox removes its folders itself.
    }
}
