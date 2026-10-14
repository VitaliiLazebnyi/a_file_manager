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
import ViewOptionsPlugin
import ViewerPlugin
import VirtualFoldersPlugin

/// The plugins that make up the program.
public enum StandardPlugins {
    public static let productName = "A File Manager"

    /// The order decides where entries appear inside a menu section; nothing else depends on it.
    /// Tests pass a pasteboard of their own and keep other applications from being started.
    public static func make(pasteboard: NSPasteboard = .general, launchesApplications: Bool = true) -> [Plugin] {
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
            ConfigurationPlugin(),
        ]
    }
}
