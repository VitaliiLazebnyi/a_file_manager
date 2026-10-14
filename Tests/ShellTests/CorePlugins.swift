import AFMKernel
import AppKit
import StandardPlugins

/// The plugins the window and panel tests run with: the ones a file manager cannot do without.
/// Tests that pin down exact button, column or menu lists use this set, so they do not change
/// whenever a feature plugin adds an entry; `Application` runs the whole program.
enum CorePlugins {
    private static let names: Set<String> = [
        "LocalFileSystemPlugin", "NavigationPlugin", "ViewerPlugin", "MacIntegrationPlugin", "FileOperationsPlugin",
        "FindFilesPlugin",
        "ClipboardPlugin", "SelectionPlugin", "ViewOptionsPlugin", "FolderTabsPlugin"
    ]

    static func make() -> [any Plugin] {
        StandardPlugins.make(pasteboard: .withUniqueName(), launchesApplications: false)
            .filter { names.contains(String(describing: type(of: $0))) }
    }
}
