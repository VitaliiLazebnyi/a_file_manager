import AFMKernel
import AppKit
import StandardPlugins

/// The plugins the window and panel tests run with: the ones a file manager cannot do without.
///
/// Tests that pin down exact button, column or menu lists use this set, so they do not change
/// whenever a feature plugin adds an entry; `AppFixture.startProgram` runs the whole program.
@MainActor
internal enum CorePlugins {
    /// The type names of the plugins in the set.
    private static let names: Set<String> = [
        "LocalFileSystemPlugin", "NavigationPlugin", "ViewerPlugin", "MacIntegrationPlugin", "FileOperationsPlugin",
        "FindFilesPlugin", "ClipboardPlugin", "SelectionPlugin", "ViewOptionsPlugin", "FolderTabsPlugin"
    ]

    /// The plugins of the set, working on `pasteboard`; none of them starts other programs.
    internal static func make(pasteboard: NSPasteboard) -> [any Plugin] {
        StandardPlugins.make(pasteboard: pasteboard, launchesApplications: false)
            .filter { names.contains(String(describing: type(of: $0))) }
    }
}
