import AFMContracts
public import AFMKernel
public import AppKit

extension CommandID {
    /// Ctrl+← / Ctrl+→: shows the folder under the cursor in the left / right panel
    /// (spec 03 › Moving between directories).
    internal static let transferLeft: CommandID = "cm_TransferLeft"
    internal static let transferRight: CommandID = "cm_TransferRight"
    internal static let nextVolume: CommandID = "cm_GoToNextDrive"
    internal static let previousVolume: CommandID = "cm_GoToPreviousDrive"
    /// The reverse of Target = Source: the source panel shows the target panel's directory.
    internal static let sourceEqualsTarget: CommandID = "afm_MatchTrg"
    internal static let changeDirectoryFromClipboard: CommandID = "afm_CdFromClipboard"
    internal static let goToDesktop: CommandID = "afm_GoDesktop"
    internal static let goToDocuments: CommandID = "afm_GoDocuments"
    internal static let goToDownloads: CommandID = "afm_GoDownloads"
    internal static let goToApplications: CommandID = "afm_GoApplications"
    internal static let goToVolumes: CommandID = "afm_GoVolumes"
    internal static let goToTrash: CommandID = "afm_GoTrash"
}

/// Moving through the directory structure (spec 03 › Navigation, 06 › Navigation).
///
/// Every move asks the panel to show a location; the panel reads it in the background.
public final class NavigationPlugin: Plugin {
    public let name = "Navigation"
    private let pasteboard: NSPasteboard
    private let home: URL

    /// Tests pass a pasteboard and a home folder of their own, so they leave the user's
    /// clipboard and folders alone.
    public init(pasteboard: NSPasteboard = .general, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.pasteboard = pasteboard
        self.home = home
    }

    /// The place a directory belongs to, and the one `delta` steps further in the volume list
    /// (wrapping around): the disks when there are several, otherwise every place.
    ///
    /// Nil when there is nowhere else to go. Works on the locations alone.
    nonisolated internal static func neighbourPlace(of directory: URL, in places: [Place], delta: Int) -> Place? {
        let disks = places.filter { $0.kind == .internalDisk || $0.kind == .externalDisk }
        let candidates = disks.count > 1 ? disks : places
        guard candidates.count > 1 else {
            return candidates.first { !$0.url.isSameLocation(as: directory) }
        }
        // The place that holds the directory is the one with the longest path around it.
        let current = candidates.indices
            .filter {
                directory.isSameLocation(as: candidates[$0].url) || directory.isInside(candidates[$0].url)
                    || (candidates[$0].url.path == "/" && candidates[$0].url.scheme == directory.scheme)
            }
            .max { candidates[$0].url.path.count < candidates[$1].url.path.count }
        guard let current else {
            return delta >= 0 ? candidates.first : candidates.last
        }
        return candidates[((current + delta) % candidates.count + candidates.count) % candidates.count]
    }

    /// The first line of a text from the clipboard as a path: without the quotes and spaces a
    /// path copied from a terminal or a document tends to come with.
    ///
    /// Nil when nothing is left.
    nonisolated internal static func path(fromClipboard text: String) -> String? {
        // Only the first line that has anything on it is looked at, however long the text is: the
        // first 8 KB of it (a path is not longer), cut at a byte, which only touches the last character.
        let head = text.utf8.count > 8_192 ? String(decoding: text.utf8.prefix(8_192), as: UTF8.self) : text
        let line =
            head.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isNewline).first
            .map(
                String.init
            ) ?? ""
        let path = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return path.isEmpty ? nil : path
    }

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

        init(_ pasteboard: NSPasteboard) { self.pasteboard = pasteboard }

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
            let path = pasteboard.string(forType: .string).flatMap(NavigationPlugin.path(fromClipboard:))
            // An empty answer is asked again: the text may not have been put there yet.
            if path != nil { pathRead = (count, path) }
            return path
        }
    }

    public func start(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        // Some handlers run other commands; the registry keeps them, so they hold it unowned.
        unowned let commands = kernel.commands
        let source = { kernel.panels.source }
        let target = { kernel.panels.target }

        func goToParent() {
            if let parent = source().model.parentTarget { source().show(parent.location, focus: parent.focus) }
        }

        /// Enter: `[..]` goes up, a folder is entered, a file goes to the first opener that takes it.
        func open(enterPackages: Bool) {
            let panel = source()
            guard let item = panel.model.cursorItem else {
                if panel.model.cursorIsOnParentRow { goToParent() }
                return
            }
            if item.isFolder || (enterPackages && item.isDirectory) {
                panel.show(item.url)
            } else if !kernel.openers.open(item, in: panel) {
                commands.onRejected()
            }
        }

        commands.register(Command(.open, "Open", [Shortcut(.returnKey), Shortcut(.enter), .cmd("o")])) {
            open(enterPackages: false)
        }
        commands.register(
            Command(
                .goToDirectory,
                "Open Directory or Package",
                [Shortcut(.downArrow, .command), Shortcut(.pageDown, .control)]
            )
        ) {
            open(enterPackages: true)
        }
        commands.register(
            Command(
                .goToParent,
                "Parent Directory",
                [Shortcut(.upArrow, .command), Shortcut(.backspace), Shortcut(.pageUp, .control)]
            ),
            enabled: { source().model.parentTarget != nil },
            goToParent
        )
        commands.register(
            Command(.goToRoot, "Root Directory", [.cmd("\\"), Shortcut(.character("\\"), .control)]),
            enabled: { source().model.rootTarget != nil }
        ) {
            if let root = source().model.rootTarget { source().show(root.location, focus: root.focus) }
        }
        commands.register(
            Command(.goBack, "Go Back", [.cmd("["), Shortcut(.leftArrow, .option)]),
            enabled: { source().model.backLocation != nil }
        ) {
            if let location = source().model.backLocation { source().show(location, history: .step(-1)) }
        }
        commands.register(
            Command(.goForward, "Go Forward", [.cmd("]"), Shortcut(.rightArrow, .option)]),
            enabled: { source().model.forwardLocation != nil }
        ) {
            if let location = source().model.forwardLocation { source().show(location, history: .step(1)) }
        }
        commands.register(Command(.goHome, "Home", [.cmd("h", .shift)])) { [home] in
            source().show(home)
        }
        // The Mac's standard places, as in Finder's Go menu (in place of the Windows-only
        // Desktop, Control Panel and Recycle Bin folders of the specification).
        let standardPlaces: [(CommandID, String, String, URL)] = [
            (.goToDesktop, "Desktop", "menubar.dock.rectangle", home.appending(name: "Desktop")),
            (.goToDocuments, "Documents", "doc", home.appending(name: "Documents")),
            (.goToDownloads, "Downloads", "arrow.down.circle", home.appending(name: "Downloads")),
            (
                .goToApplications, "Applications", "square.grid.2x2",
                URL(fileURLWithPath: "/Applications", isDirectory: true)
            ),
            (.goToVolumes, "Volumes", "externaldrive", URL(fileURLWithPath: "/Volumes", isDirectory: true)),
            (.goToTrash, "Trash", "trash", home.appending(name: ".Trash"))
        ]
        for (id, title, symbol, location) in standardPlaces {
            commands.register(Command(id, title)) { source().show(location) }
            kernel.toolbar.setSymbol(symbol, for: id)
        }
        commands.register(Command(.editPath, "Go to Folder…", [.cmd("g", .shift)])) {
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
        commands.register(
            Command(.changeDirectory, "Change Directory"),
            parameterized: { argument in
                let current = source().model.directory
                if let location = argument.location
                    ?? argument.text.map({ kernel.fileSystems.location(from: $0, relativeTo: current) })
                {
                    source().show(location)
                }
            }
        )
        // Offered while the clipboard holds text. Asking the clipboard for the kinds of its contents
        // is done once for each change of the clipboard (`changeCount`); the menus show that answer.
        // The clipboard is used on the main thread only: `NSPasteboard` is not safe to use from
        // two threads (a background read beside a copy on the main thread crashed in the tests).
        let clipboard = ClipboardText(pasteboard)
        commands.register(
            Command(.changeDirectoryFromClipboard, "Go to Path from Clipboard"),
            enabled: { clipboard.hasText }
        ) {
            guard let path = clipboard.path else {
                return
            }
            // The path of a file leads to its folder, with the cursor on the file.
            source().show(kernel.fileSystems.location(from: path, relativeTo: source().model.directory))
        }
        commands.register(Command(.reread, "Reread Source", [.cmd("r"), .f(2), Shortcut(.character("r"), .control)])) {
            kernel.panels.all.forEach { $0.reload() }
        }
        commands.register(Command(.targetEqualsSource, "Target = Source")) {
            target().show(source().model.directory)
        }
        commands.register(Command(.sourceEqualsTarget, "Source = Target")) {
            source().show(target().model.directory)
        }
        /// Ctrl+← / Ctrl+→: the folder under the cursor is shown in the panel on that side; when
        /// the cursor is not on a folder, the current directory is. Pressed in the panel of that
        /// very side, the panel takes the other panel's directory.
        func transfer(to panel: any PanelHandle) {
            let from = source()
            if from === panel {
                panel.show(target().model.directory)
            } else {
                panel.show(from.model.cursorItem.flatMap { $0.isFolder ? $0.url : nil } ?? from.model.directory)
            }
        }
        commands.register(Command(.transferLeft, "Show Folder in Left Panel", [Shortcut(.leftArrow, .control)])) {
            transfer(to: kernel.panels.left)
        }
        commands.register(Command(.transferRight, "Show Folder in Right Panel", [Shortcut(.rightArrow, .control)])) {
            transfer(to: kernel.panels.right)
        }
        /// The next or previous entry of the volume list, counted from where the panel is.
        func goToVolume(_ delta: Int) {
            let (providers, current, panel) = (kernel.fileSystems.all, source().model.directory, source())
            // The disks are asked in the background: the first answer can take a moment.
            kernel.jobs.run(
                title: "Go to volume",
                work: { _ -> Place? in
                    Self.neighbourPlace(of: current, in: providers.flatMap { $0.places() }, delta: delta)
                },
                // The registry is kept until the answer is in: the kernel may have gone by then.
                completion: { [commands] place in
                    guard let place else {
                        return commands.onRejected()
                    }
                    panel.show(place.url)
                }
            )
        }
        commands.register(Command(.nextVolume, "Next Volume")) { goToVolume(1) }
        commands.register(Command(.previousVolume, "Previous Volume")) { goToVolume(-1) }
        commands.register(
            Command(.exchangePanels, "Exchange Directories", [.cmd("u"), Shortcut(.character("u"), .control)])
        ) {
            let (sourceDirectory, targetDirectory) = (source().model.directory, target().model.directory)
            source().show(targetDirectory)
            target().show(sourceDirectory)
        }

        kernel.menus.add([.open], to: .filesOpen)
        kernel.menus.add(
            [.goBack, .goForward, .goToParent, .goToDirectory, .goToRoot, .goHome, .editPath],
            to: .commandsGo
        )
        kernel.menus.add([.changeDirectoryFromClipboard], to: .commandsGo)
        kernel.menus.add(standardPlaces.map(\.0), to: MenuSection(.commands, order: 12))
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
}
