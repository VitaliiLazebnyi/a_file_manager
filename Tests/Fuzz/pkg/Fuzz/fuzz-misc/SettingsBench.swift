import AFMKernel
import Foundation
import FuzzCore
import TestSupport

@testable import ConfigurationPlugin

/// A program with the Configuration plugin, two panels on a memory file system and settings in memory.
@MainActor
internal final class SettingsBench {
    /// The settings the program stores.
    internal let settings = MemorySettings()
    /// The Configuration plugin.
    internal let plugin: ConfigurationPlugin
    /// The program around it.
    internal let bench: TestBench
    /// The file system both panels show.
    internal let memory = MemoryFileSystem()

    /// A fresh program; its lists folder is in the worker's folder.
    internal init() {
        let lists = URL(fileURLWithPath: fzWorkDir + "/lists")
        plugin = ConfigurationPlugin(
            launchesApplications: false,
            background: nil,
            listFolder: lists
        ) {
            [
                "extra.key", "places.hotlist", "places.history.left", "places.history.right",
                "places.history.frequent"
            ]
        }
        memory.addFile("/A/my file.txt")
        memory.addFile("/A/-rf")
        memory.addFile("/A/one.txt")
        _ = memory.addDirectory("/B")
        bench = TestBench(
            plugins: [plugin],
            fileSystems: [memory],
            left: memory.url("/A"),
            right: memory.url("/B"),
            settings: settings
        )
    }

    deinit {
        // Nothing to release.
    }
}
