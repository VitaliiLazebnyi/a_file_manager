import AFMContracts
public import AFMKernel
public import AppKit

/// Moving through the directory structure (spec 03 › Navigation, 06 › Navigation).
///
/// Every move asks the panel to show a location; the panel reads it in the background.
public final class NavigationPlugin: Plugin {
    /// What the commands and menus need of the clipboard.
    ///
    /// Its text is copied (all of it, if it is a long one) only when a command needs it, and once
    /// for each change count; the menus ask only for the kinds of its contents, which costs no
    /// copy: a yes is kept for as long as the change count stays, a no is asked again each time,
    /// since a program that fills the clipboard may add the text after the count was changed. Main
    /// thread only (`NSPasteboard` is not safe to use from two threads at once).
    @MainActor
    private final class ClipboardText {
        private let pasteboard: NSPasteboard
        private var textCount: Int?
        private var pathRead: (count: Int, path: String?)?

        var hasText: Bool {
            let count = pasteboard.changeCount
            if textCount == count {
                return true
            }
            guard pasteboard.availableType(from: [.string]) != nil else {
                return false
            }
            textCount = count
            return true
        }

        /// The path the clipboard's text starts with; the text is read once for each change.
        var path: String? {
            let count = pasteboard.changeCount
            if let pathRead, pathRead.count == count {
                return pathRead.path
            }
            let found = pasteboard.string(forType: .string).flatMap(NavigationPlugin.path(fromClipboard:))
            // An empty answer is asked again: the text may not have been put there yet.
            if found != nil { pathRead = (count, found) }
            return found
        }

        init(_ pasteboard: NSPasteboard) { self.pasteboard = pasteboard }

        deinit {
            // Nothing to release.
        }
    }

    /// One of the Mac's standard places, as in Finder's Go menu, with its command.
    private struct StandardPlace {
        let id: CommandID
        let title: String
        let symbol: String
        let location: URL

        init(_ id: CommandID, _ title: String, _ symbol: String, _ location: URL) {
            self.id = id
            self.title = title
            self.symbol = symbol
            self.location = location
        }
    }

    /// The plugin's name, for the log.
    public let name = "Navigation"
    private let pasteboard: NSPasteboard
    private let home: URL

    /// Tests pass a pasteboard and a home folder of their own, so they leave the user's
    /// clipboard and folders alone.
    public init(pasteboard: NSPasteboard = .general, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.pasteboard = pasteboard
        self.home = home
    }

    /// Puts the commands into the menus, the toolbar and the context menu.
    private static func addToMenus(_ kernel: Kernel, standardPlaces: [CommandID]) {
        kernel.menus.add([.open], to: .filesOpen)
        kernel.menus.add(
            [.goBack, .goForward, .goToParent, .goToDirectory, .goToRoot, .goHome, .editPath],
            to: .commandsGo
        )
        kernel.menus.add([.changeDirectoryFromClipboard], to: .commandsGo)
        kernel.menus.add(standardPlaces, to: MenuSection(.commands, order: 12))
        kernel.menus.add([.previousVolume, .nextVolume], to: .commandsVolumes)
        kernel.menus.add(
            [.targetEqualsSource, .sourceEqualsTarget, .exchangePanels, .transferLeft, .transferRight, .reread],
            to: .commandsPanels
        )
        kernel.toolbar.add(
            .goBack,
            symbol: "chevron.left",
            group: 10,
            hint: "Go back to the folder you were in before."
        )
        kernel.toolbar.add(.goForward, symbol: "chevron.right", group: 10, hint: "Go forward again after going back.")
        kernel.toolbar.add(
            .goToParent,
            symbol: "arrow.up",
            group: 10,
            hint: "Go up to the folder that contains this one."
        )
        kernel.toolbar.add(
            .reread,
            symbol: "arrow.clockwise",
            group: 10,
            hint: "Read the folder again, to show the latest changes."
        )
        kernel.toolbar.setSymbol("house", for: .goHome)
        kernel.toolbar.setSymbol("arrow.left.arrow.right", for: .exchangePanels)
        kernel.menus.addToContextMenu([.open], in: .open, onItemOnly: true)
        kernel.menus.addToContextMenu([.reread], in: .tools)
    }

    /// Registers the navigation commands and puts them into the menus, the toolbar and the
    /// context menu; main thread, once.
    public func start(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        registerOpening(in: kernel)
        registerHistoryMoves(in: kernel)
        let standardPlaces = registerPlaces(in: kernel)
        registerPaths(in: kernel)
        registerPanelMoves(in: kernel)
        registerVolumeMoves(in: kernel)
        Self.addToMenus(kernel, standardPlaces: standardPlaces)
    }

    /// Home and the Mac's standard places, as in Finder's Go menu (in place of the Windows-only
    /// Desktop, Control Panel and Recycle Bin folders of the specification); returns the commands
    /// of the standard places.
    private func registerPlaces(in owner: Kernel) -> [CommandID] {
        unowned let kernel = owner
        kernel.commands.register(Command(.goHome, "Home", [.cmd("h", .shift)])) { [home] in
            kernel.panels.source.show(home)
        }
        let standardPlaces = [
            StandardPlace(.goToDesktop, "Desktop", "menubar.dock.rectangle", home.appending(name: "Desktop")),
            StandardPlace(.goToDocuments, "Documents", "doc", home.appending(name: "Documents")),
            StandardPlace(.goToDownloads, "Downloads", "arrow.down.circle", home.appending(name: "Downloads")),
            StandardPlace(
                .goToApplications,
                "Applications",
                "square.grid.2x2",
                URL(fileURLWithPath: "/Applications", isDirectory: true)
            ),
            StandardPlace(
                .goToVolumes,
                "Volumes",
                "externaldrive",
                URL(fileURLWithPath: "/Volumes", isDirectory: true)
            ),
            StandardPlace(.goToTrash, "Trash", "trash", home.appending(name: ".Trash"))
        ]
        for place in standardPlaces {
            kernel.commands.register(Command(place.id, place.title)) { kernel.panels.source.show(place.location) }
            kernel.toolbar.setSymbol(place.symbol, for: place.id)
        }
        return standardPlaces.map(\.id)
    }

    /// Go to Folder, `cd <location>` and the path on the clipboard.
    private func registerPaths(in owner: Kernel) {
        unowned let kernel = owner
        let source = { kernel.panels.source }
        kernel.commands.register(Command(.editPath, "Go to Folder…", [.cmd("g", .shift)])) {
            let current = source().model.directory
            guard let text = kernel.interaction.prompt("Go to folder:", value: kernel.fileSystems.displayPath(current))
            else {
                return
            }
            let location = kernel.fileSystems.location(from: text, relativeTo: current)
            // An address typed into the field is one the user chose: a server need not be asked about again.
            kernel.services.find((any ServerConsentService).self)?.userChose(location)
            source().show(location)
        }
        // `cd <location>`, for other plugins and later the command line.
        kernel.commands.register(Command(.changeDirectory, "Change Directory")) { argument in
            let current = source().model.directory
            if let location = argument.location
                ?? argument.text.map({ text in kernel.fileSystems.location(from: text, relativeTo: current) })
            {
                source().show(location)
            }
        }
        // Offered while the clipboard holds text. Asking the clipboard for the kinds of its contents
        // is done once for each change of the clipboard (`changeCount`); the menus show that answer.
        // The clipboard is used on the main thread only: `NSPasteboard` is not safe to use from
        // two threads (a background read beside a copy on the main thread crashed in the tests).
        let clipboard = ClipboardText(pasteboard)
        kernel.commands.register(
            Command(.changeDirectoryFromClipboard, "Go to Path from Clipboard"),
            enabled: { clipboard.hasText },
            {
                guard let path = clipboard.path else {
                    return
                }
                // The path of a file leads to its folder, with the cursor on the file.
                source().show(kernel.fileSystems.location(from: path, relativeTo: source().model.directory))
            }
        )
    }

    deinit {
        // Nothing to release.
    }
}
