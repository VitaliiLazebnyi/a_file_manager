public import AFMKernel
public import AppKit
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
import ViewOptionsPlugin
import ViewerPlugin
import VirtualFoldersPlugin

/// The plugins that make up the program.
public enum StandardPlugins {
    /// The program's name, for the menu, window titles and dialogs.
    public static let productName = "A File Manager"

    /// Makes one of each plugin of the program, in the order they are started.
    ///
    /// Main thread only.
    /// The order decides where entries appear inside a menu section; nothing else depends on it.
    /// Tests pass a pasteboard of their own and turn `launchesApplications` off: then no other
    /// application is started, no tool window is put on screen, and no modal dialog is run.
    @MainActor
    @preconcurrency
    public static func make(pasteboard: NSPasteboard = .general, launchesApplications: Bool = true) -> [any Plugin] {
        [
            LocalFileSystemPlugin(),
            ArchivesPlugin(launchesApplications: launchesApplications),
            NetworkPlugin(launchesApplications: launchesApplications),
            VirtualFoldersPlugin(),
            NavigationPlugin(),
            PlacesPlugin(opensWindows: launchesApplications),
            ViewerPlugin(showsWindows: launchesApplications),
            MacIntegrationPlugin(launchesApplications: launchesApplications),
            FileOperationsPlugin(),
            FilePropertiesPlugin(launchesApplications: launchesApplications),
            MultiRenamePlugin(opensWindows: launchesApplications),
            CompareContentPlugin(opensWindows: launchesApplications),
            FileToolsPlugin(),
            FindFilesPlugin(opensWindows: launchesApplications),
            DirectorySyncPlugin(opensWindows: launchesApplications),
            SystemToolsPlugin(launchesApplications: launchesApplications),
            ClipboardPlugin(pasteboard: pasteboard),
            SelectionPlugin(),
            ViewOptionsPlugin(),
            FolderTabsPlugin(),
            ConfigurationPlugin(launchesApplications: launchesApplications)
        ]
    }
}
