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
    /// Tests pass a pasteboard of their own and keep other applications from being started.
    @MainActor
    @preconcurrency
    public static func make(pasteboard: NSPasteboard = .general, launchesApplications: Bool = true) -> [any Plugin] {
        [
            LocalFileSystemPlugin(),
            ArchivesPlugin(launchesApplications: launchesApplications),
            NetworkPlugin(launchesApplications: launchesApplications),
            VirtualFoldersPlugin(),
            NavigationPlugin(),
            PlacesPlugin(),
            ViewerPlugin(),
            MacIntegrationPlugin(launchesApplications: launchesApplications),
            FileOperationsPlugin(),
            FilePropertiesPlugin(launchesApplications: launchesApplications),
            MultiRenamePlugin(),
            CompareContentPlugin(),
            FileToolsPlugin(),
            FindFilesPlugin(),
            DirectorySyncPlugin(),
            SystemToolsPlugin(launchesApplications: launchesApplications),
            ClipboardPlugin(pasteboard: pasteboard),
            SelectionPlugin(),
            ViewOptionsPlugin(),
            FolderTabsPlugin(),
            ConfigurationPlugin()
        ]
    }
}
