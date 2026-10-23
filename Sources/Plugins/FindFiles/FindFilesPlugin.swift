import AFMContracts
public import AFMKernel
import AppKit

/// Find Files (spec 09 › Find Files).
public final class FindFilesPlugin: Plugin {
    /// The plugin's name in the list of plugins.
    public let name = "Find Files"
    /// Puts a window of Find Files on screen.
    ///
    /// Tests replace it, so that no window shows in the session they run in, and look at what it
    /// was asked to show.
    internal var present: @MainActor (NSWindowController) -> Void = { $0.showWindow(nil) }
    private var window: FindFilesWindowController?
    /// The windows of "Find Files in Separate Window", each until it is closed.
    private var separateWindows: [FindFilesWindowController] = []

    /// With `opensWindows` off, the windows are made but never put on screen (for tests of the
    /// whole program).
    public init(opensWindows: Bool = true) {
        if !opensWindows {
            present = { _ in
                // The window is made, but stays off screen.
            }
        }
    }

    /// Registers the commands, the menu entries, the toolbar button and the preferences of Find Files.
    public func start(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        kernel.fileSystems.addVolumeReleaser { [weak self] volume in self?.cancelSearches(reading: volume) }
        registerCommands(in: kernel)
        kernel.menus.add([.searchFor], to: .filesTools)
        kernel.menus.add([.searchStandalone, .searchInCursorDirectory], to: .commandsTools)
        kernel.toolbar.add(
            .searchFor,
            symbol: "magnifyingglass",
            group: 40,
            hint: "Search for files by name, text inside, size or date."
        )
        kernel.preferences.add(
            PreferencePage(
                title: "Find Files",
                preferences: [
                    Preference(
                        FindFilesWindowController.keepResultsKey,
                        "Keep the results of the last search when the window is opened again",
                        .flag(default: true)
                    ),
                    Preference(
                        FindFilesWindowController.spotlightKey,
                        "Search with Spotlight unless told otherwise",
                        .flag(default: false)
                    ),
                    Preference(
                        FindFilesWindowController.historyLengthKey,
                        "Entries kept in the histories of the search fields",
                        .choice(FindFilesWindowController.historyLengths.map(String.init), default: 1)
                    )
                ]
            )
        )
    }

    /// Closes the windows.
    public func stop() {
        window?.close()
        for separate in separateWindows {
            separate.close()
        }
    }

    /// The one window of `cm_SearchFor`; it keeps its fields and results between uses.
    internal func mainWindow(in kernel: Kernel) -> FindFilesWindowController {
        let controller = window ?? FindFilesWindowController(kernel: kernel)
        controller.present = present
        window = controller
        return controller
    }

    /// The three commands that open Find Files: the main window, a separate one, and the main window in the
    /// folder under the cursor.
    private func registerCommands(in owner: Kernel) {
        // The kernel keeps the commands; they must not keep it in turn.
        unowned let kernel = owner
        let source = { kernel.panels.source.model }
        kernel.commands.register(
            Command(.searchFor, "Find Files…", [.f(7, .option), .cmd("f")], runsDuringJobs: true)
        ) { [self] argument in
            mainWindow(in: kernel)
                .show(
                    startingIn: argument.location ?? source().directory,
                    includeHidden: source().showHidden
                )
        }
        kernel.commands.register(
            Command(
                .searchStandalone,
                "Find Files in Separate Window…",
                [.f(7, [.option, .shift])],
                runsDuringJobs: true
            )
        ) { [self] in
            let controller = FindFilesWindowController(kernel: kernel, title: "Find Files (separate)")
            controller.onClose = { [weak self] closed in self?.separateWindows.removeAll { $0 === closed } }
            controller.present = present
            separateWindows.append(controller)
            controller.show(startingIn: source().directory, includeHidden: source().showHidden)
        }
        kernel.commands.register(
            Command(.searchInCursorDirectory, "Find Files in Folder under Cursor…", runsDuringJobs: true),
            enabled: { source().cursorItem?.isDirectory == true },
            parameterized: { [self] _ in
                // Enabled only while the cursor is on a folder.
                if let folder = source().cursorItem, folder.isDirectory {
                    mainWindow(in: kernel).show(startingIn: folder.url, includeHidden: source().showHidden)
                }
            }
        )
    }

    /// Stops the searches of every window that read `volume`, which is about to be ejected.
    private func cancelSearches(reading volume: URL) {
        for each in [window].compactMap(\.self) + separateWindows {
            each.cancelSearch(ifItReads: volume)
        }
    }

    deinit {
        // Nothing to release.
    }
}
