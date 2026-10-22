import AFMKernel
import AppKit
import ArchivesPlugin
import ClipboardPlugin
import CompareContentPlugin
import ConfigurationPlugin
import DirectorySyncPlugin
import FileOperationsPlugin
import FilePropertiesPlugin
import FileToolsPlugin
import FindFilesPlugin
import FolderTabsPlugin
import LocalFileSystemPlugin
import MacIntegrationPlugin
import MultiRenamePlugin
import NavigationPlugin
import NetworkPlugin
import PlacesPlugin
import SelectionPlugin
import SystemToolsPlugin
import TestSupport
import Testing
import ViewOptionsPlugin
import ViewerPlugin
import VirtualFoldersPlugin

/// The kernel keeps every plugin and whatever a plugin registers (commands, file systems,
/// openers, questions); none of that may keep the kernel in turn, or the program never lets go
/// of any of it.
///
/// Each plugin is started on its own, used a little, and must be gone with its kernel when the
/// bench is.
@MainActor
@Suite
struct PluginLifetimes {
    nonisolated static let names = [
        "LocalFileSystem", "Archives", "Network", "VirtualFolders", "Navigation", "Places", "Viewer", "MacIntegration",
        "FileOperations", "FileProperties", "MultiRename", "CompareContent", "FileTools", "FindFiles", "DirectorySync",
        "SystemTools", "Clipboard", "Selection", "ViewOptions", "FolderTabs", "Configuration"
    ]

    /// Each plugin as the tests start it: nothing is launched and nothing is written outside.
    static let plugins: [String: (NSPasteboard) -> any Plugin] = [
        "LocalFileSystem": { _ in LocalFileSystemPlugin() },
        "Archives": { _ in ArchivesPlugin(flushDelay: nil, launchesApplications: false) },
        "Network": { _ in NetworkPlugin(launchesApplications: false, passwords: MemoryPasswords()) },
        "VirtualFolders": { _ in VirtualFoldersPlugin() },
        "Navigation": { NavigationPlugin(pasteboard: $0) },
        "Places": { _ in PlacesPlugin(keepsTreesOnDisk: false, favorites: []) },
        "Viewer": { _ in ViewerPlugin(overlayHost: { _ in nil }, showsWindows: false) },
        "MacIntegration": { MacIntegrationPlugin(launchesApplications: false, pasteboard: $0) { _ in [] } },
        "FileOperations": { _ in FileOperationsPlugin() },
        "FileProperties": { _ in FilePropertiesPlugin(launchesApplications: false) },
        "MultiRename": { _ in MultiRenamePlugin(opensWindows: false) },
        "CompareContent": { _ in CompareContentPlugin(opensWindows: false) },
        "FileTools": { FileToolsPlugin(pasteboard: $0) },
        "FindFiles": { _ in FindFilesPlugin() },
        "DirectorySync": { _ in DirectorySyncPlugin(opensWindows: false) },
        "SystemTools": { _ in SystemToolsPlugin(launchesApplications: false) },
        "Clipboard": { ClipboardPlugin(pasteboard: $0) },
        "Selection": { SelectionPlugin(pasteboard: $0, background: false) },
        "ViewOptions": { _ in ViewOptionsPlugin() },
        "FolderTabs": { _ in FolderTabsPlugin() },
        "Configuration": { _ in ConfigurationPlugin(launchesApplications: false, background: nil) { [] } }
    ]

    @Test(arguments: names)
    func thePluginGoesWithItsKernel(_ name: String) throws {
        let scratch = ScratchPasteboard()
        weak var kernel: Kernel?
        weak var commands: CommandRegistry?
        do {
            let memory = MemoryFileSystem()
            memory.addFile("/A/one.txt", "1")
            memory.addDirectory("/B")
            let make = try #require(Self.plugins[name])
            let plugin = make(scratch.pasteboard)
            let bench = TestBench(
                plugins: [plugin],
                fileSystems: [memory],
                left: memory.url("/A"),
                right: memory.url("/B")
            )
            // Every command is asked whether it may run, as the menus and buttons do.
            for command in bench.commands.all {
                _ = bench.commands.isEnabled(command.id)
                _ = bench.commands.isChecked(command.id)
            }
            (kernel, commands) = (bench.kernel, bench.commands)
        }
        #expect(kernel == nil, "\(name) keeps the kernel")
        #expect(commands == nil, "\(name) keeps the commands")
    }

    @Test
    func theConnectionsGoWithTheNetworkPlugin() {
        weak var center: ConnectionCenter?
        weak var environment: SessionEnvironment?
        do {
            let plugin = NetworkPlugin(launchesApplications: false, passwords: MemoryPasswords())
            let memory = MemoryFileSystem()
            memory.addDirectory("/A")
            let bench = TestBench(
                plugins: [plugin],
                fileSystems: [memory],
                left: memory.url("/A"),
                right: memory.url("/A")
            )
            (center, environment) = (plugin.center, plugin.center.environment)
            #expect(bench.kernel.plugins.count == 1)
        }
        #expect(center == nil && environment == nil)
    }
}
