import AFMContracts
import AFMKernel
import AppKit

extension CommandID {
    /// A further Find Files window that searches on its own, so several searches can run side
    /// by side (the spec's "separate process", 09 › Window and modes).
    static let searchStandalone: CommandID = "cm_SearchStandalone"
    /// Find Files starting in the folder under the cursor.
    static let searchInCursorDirectory: CommandID = "cm_SearchForInCurDir"
}

/// Find Files (spec 09 › Find Files).
public final class FindFilesPlugin: Plugin {
    public let name = "Find Files"
    private var window: FindFilesWindowController?
    /// The windows of "Find Files in Separate Window", each until it is closed.
    private var separateWindows: [FindFilesWindowController] = []

    public init() {}

    public func start(in kernel: Kernel) {
        let source = { kernel.panels.source.model }
        kernel.fileSystems.addVolumeReleaser { [weak self] volume in
            guard let self else { return }
            for window in [window].compactMap({ $0 }) + separateWindows {
                window.cancelSearch(ifItReads: volume)
            }
        }
        kernel.commands.register(
            Command(.searchFor, "Find Files…", [.f(7, .option), .cmd("f")], runsDuringJobs: true),
            parameterized: { [self] argument in
                mainWindow(in: kernel).show(
                    startingIn: argument.location ?? source().directory, includeHidden: source().showHidden)
            })
        kernel.commands.register(
            Command(
                .searchStandalone, "Find Files in Separate Window…", [.f(7, [.option, .shift])], runsDuringJobs: true)
        ) { [self] in
            let controller = FindFilesWindowController(kernel: kernel, title: "Find Files (separate)")
            controller.onClose = { [weak self] closed in self?.separateWindows.removeAll { $0 === closed } }
            separateWindows.append(controller)
            controller.show(startingIn: source().directory, includeHidden: source().showHidden)
        }
        kernel.commands.register(
            Command(.searchInCursorDirectory, "Find Files in Folder under Cursor…", runsDuringJobs: true),
            enabled: { source().cursorItem?.isDirectory == true }
        ) { [self] in
            guard let folder = source().cursorItem, folder.isDirectory else { return }
            mainWindow(in: kernel).show(startingIn: folder.url, includeHidden: source().showHidden)
        }
        kernel.menus.add([.searchFor], to: .filesTools)
        kernel.menus.add([.searchStandalone, .searchInCursorDirectory], to: .commandsTools)
        kernel.toolbar.add(
            .searchFor, symbol: "magnifyingglass", group: 40,
            hint: "Search for files by name, text inside, size or date.")

        kernel.preferences.add(
            PreferencePage(
                title: "Find Files",
                preferences: [
                    Preference(
                        FindFilesWindowController.keepResultsKey,
                        "Keep the results of the last search when the window is opened again",
                        .flag(default: true)),
                    Preference(
                        FindFilesWindowController.spotlightKey, "Search with Spotlight unless told otherwise",
                        .flag(default: false)),
                    Preference(
                        FindFilesWindowController.historyLengthKey,
                        "Entries kept in the histories of the search fields",
                        .choice(FindFilesWindowController.historyLengths.map(String.init), default: 1))
                ]))
    }

    /// The one window of `cm_SearchFor`; it keeps its fields and results between uses.
    func mainWindow(in kernel: Kernel) -> FindFilesWindowController {
        let controller = window ?? FindFilesWindowController(kernel: kernel)
        window = controller
        return controller
    }

    public func stop() {
        window?.close()
        separateWindows.forEach { $0.close() }
    }
}
