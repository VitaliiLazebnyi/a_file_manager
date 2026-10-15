import AFMContracts
public import AFMKernel
public import AppKit
import UniformTypeIdentifiers

/// What the Mac itself does with files: opening them with their application or one the user
/// picks, editing in the editor of the user's choice, Quick Look, sharing, Finder tags, showing
/// them in Finder (spec 10 › Associations, 10 › Edit (F4), 05 › File and folder context menu).
/// Only files on the local disks can be handed to other applications.
///
/// Thread ownership: the plugin's state and its commands belong to the main thread; looking
/// for applications, reading or writing tags, and picking the marked items out of a long list
/// happen in the background.
public final class MacIntegrationPlugin: Plugin {
    public let name = "Mac integration"
    /// Off in tests, so they do not start other applications or show system panels; what
    /// would have been opened is recorded in `opened` and `log` either way.
    private let launchesApplications: Bool
    private let pasteboard: NSPasteboard
    private let applications: @Sendable (URL) -> [URL]
    /// The files most recently handed to an application (or that would have been); for tests.
    public private(set) var opened: [URL] = []
    /// What was done, one line each, the most recent ones: `edit TextEdit /a/b.txt`,
    /// `open-with Preview /a/c.png`, `open /a/d`, `quicklook /a/e`, `share /a/f`, `tags /a/g: Red, Work`.
    public private(set) var log: [String] = []
    /// Both lists are kept to this length; a program that runs for weeks must not grow with every click.
    private static let recordLimit = 256

    private func remember(opened urls: [URL]) {
        opened = Array((opened + urls).suffix(Self.recordLimit))
    }

    /// A line of the log. Names come from the disk: a line break in one cannot make a second line.
    private func remember(_ line: String) {
        log.append(DisplayText.oneLine(line, limit: 2_000))
        if log.count > Self.recordLimit * 2 {
            log.removeFirst(log.count - Self.recordLimit)
        }
    }

    /// The files of a log line: their paths while they are few, their number when they are
    /// many (a line with every path of a large selection would be megabytes).
    private static func described(_ urls: [URL]) -> String {
        urls.count <= 8 ? urls.map(\.path).joined(separator: " ") : "\(urls.count) items"
    }

    /// From this many marked items on, they are picked out off the main thread.
    static let backgroundListThreshold = 5_000
    /// The most items Finder is asked to select, and the most that are shared, at a time.
    nonisolated static let revealLimit = 1_000
    static let shareLimit = 1_000
    /// Stands for Launch Services in `BlockingCalls`: used for nothing but what object it is.
    private final class LaunchServices: Sendable {}
    nonisolated private static let launchServices = LaunchServices()

    /// The local operands of a panel, worked on by `work` and handed to `deliver` on the main
    /// thread. With many marked items both happen on a background thread first (the marks and
    /// the list are taken as they are, which copies nothing); with few, everything is done at
    /// once, here. `deliver` runs from the main run loop, not from a block of the main queue:
    /// it may ask the user something.
    private func withLocalOperands<Result: Sendable>(
        of model: PanelModel,
        _ work: @escaping @Sendable ([URL]) -> Result,
        then deliver: @escaping @MainActor @Sendable (Result) -> Void
    ) {
        let operands = model.operandsSnapshot()
        @Sendable func urls() -> [URL] { operands.items().map(\.url).filter(\.isFileURL) }
        guard operands.markedCount >= Self.backgroundListThreshold else {
            deliver(work(urls()))
            return
        }
        DispatchQueue.global(qos: .userInitiated)
            .async {
                let result = work(urls())
                // The main run loop runs its blocks on the main thread.
                RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { deliver(result) } }
                CFRunLoopWakeUp(CFRunLoopGetMain())
            }
    }

    /// What the open Quick Look panel was given last: the panel's list and marks then.
    private var followed: (model: ObjectIdentifier, marked: Int, listVersion: Int)?
    private var followTicket = 0

    /// Has the open Quick Look panel show what the source panel now has. A move of the cursor
    /// costs nothing that grows with the list: without marked items the file under the cursor
    /// is shown, and with them the panel keeps showing those until they or the list change.
    private func follow(_ model: PanelModel) {
        let marked = model.selectionCount
        let state = (ObjectIdentifier(model), marked, model.listVersion)
        guard marked > 0 else {
            followed = nil
            followTicket += 1
            quickLook.follow(model.cursorItem.flatMap { $0.url.isFileURL ? [$0.url] : nil } ?? [])
            return
        }
        if let followed, followed == state { return }
        followed = state
        followTicket += 1
        let ticket = followTicket
        withLocalOperands(of: model, { $0 }) { [weak self] urls in
            // Something newer is being shown by now.
            guard let self, followTicket == ticket, quickLook.isVisible else { return }
            quickLook.follow(urls)
        }
    }
    private let quickLook = QuickLookController()
    private var subscription: AnyObject?
    private var sharingPicker: NSSharingServicePicker?

    /// The preference that names the editor for F4: an application's name, its path, or its
    /// bundle identifier.
    public static let editorKey = "macIntegration.editor"
    public static let defaultEditor = "TextEdit"

    public static let openWith: CommandID = "afm_OpenWith"
    public static let openWithDefault: CommandID = "afm_OpenWithDefault"
    public static let chooseEditor: CommandID = "afm_ChooseEditor"
    public static let quickLook: CommandID = "afm_QuickLook"
    public static let share: CommandID = "afm_Share"
    public static let editTags: CommandID = "afm_EditTags"
    public static let copyAsPathname: CommandID = "afm_CopyAsPathname"

    /// Tests pass a pasteboard of their own and say which applications open a file.
    public init(
        launchesApplications: Bool = true,
        pasteboard: NSPasteboard = .general,
        applications: (@Sendable (URL) -> [URL])? = nil
    ) {
        self.launchesApplications = launchesApplications
        self.pasteboard = pasteboard
        self.applications = applications ?? { Self.installedApplications(for: $0) }
    }

    /// The applications that open a file, the default one first. Launch Services looks at the
    /// file to know its type: not for the main thread.
    nonisolated private static func installedApplications(for url: URL) -> [URL] {
        let workspace = NSWorkspace.shared
        var all = workspace.urlsForApplications(toOpen: url)
        if let preferred = workspace.urlForApplication(toOpen: url) {
            all.removeAll { $0 == preferred }
            all.insert(preferred, at: 0)
        }
        return all
    }

    /// Finds the application the editor preference names. Looks at the disk: not for the main thread.
    nonisolated static func editorApplication(named text: String) -> URL {
        let fallback = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let text = text.trimmingCharacters(in: .whitespaces)
        let fm = FileManager.default
        if text.hasPrefix("/") || text.hasPrefix("~") {
            let path = NSString(string: text).expandingTildeInPath
            return fm.fileExists(atPath: path) ? URL(fileURLWithPath: path) : fallback
        }
        let name = text.hasSuffix(".app") ? String(text.dropLast(4)) : text
        guard !name.isEmpty else { return fallback }
        let folders = [
            "/Applications", "/System/Applications", "/Applications/Utilities", "/System/Applications/Utilities",
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        ]
        if let path = folders.map({ $0 + "/" + name + ".app" }).first(where: fm.fileExists(atPath:)) {
            return URL(fileURLWithPath: path)
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: text) ?? fallback
    }

    private static func applicationName(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    private func open(_ urls: [URL], with application: URL?) {
        remember(opened: urls)
        guard launchesApplications else { return }
        if let application {
            NSWorkspace.shared.open(
                urls,
                withApplicationAt: application,
                configuration: NSWorkspace.OpenConfiguration()
            )
        } else {
            // Launch Services answers each file in its own time; none of them holds up the main thread.
            urls.forEach { NSWorkspace.shared.open($0, configuration: NSWorkspace.OpenConfiguration()) }
        }
    }

    public func start(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        let commands = kernel.commands
        // The system's Quick Look panel keeps the file it previews: it closes before the drive is ejected.
        kernel.fileSystems.addVolumeReleaser { [weak self] volume in self?.quickLook.close(ifShowing: volume) }
        let model = { kernel.panels.source.model }
        let cursorFile = { model().cursorFile.flatMap { $0.url.isFileURL ? $0.url : nil } }
        let cursorItem = { model().cursorItem.flatMap { $0.url.isFileURL ? $0.url : nil } }
        /// The cheap test for the toolbar, which asks ten times a second: the list of operands
        /// can be a whole folder and is made only when a command runs.
        let hasLocalOperands = { () -> Bool in
            let panel = model()
            return panel.hasOperands && (panel.directory.isFileURL || panel.cursorItem?.url.isFileURL == true)
        }

        // The general opener: any local file goes to its application. Plugins that understand
        // particular files (archives) add openers with a higher priority.
        kernel.openers.add(priority: 0) { [self] file, _ in
            guard file.url.isFileURL else { return false }
            open([file.url], with: nil)
            return true
        }

        // F4 starts the editor the user chose (spec 10 › Editor and parameters).
        commands.register(
            Command(.edit, "Edit", [.f(4)], barLabel: "Edit", runsDuringJobs: true),
            enabled: { cursorFile() != nil },
            parameterized: { [self] argument in
                guard let url = argument.location ?? cursorFile(), url.isFileURL else { return }
                let editor = kernel.settings.text(
                    Self.editorKey,
                    default: Self.defaultEditor
                )
                remember(opened: [url])
                remember("edit \(DisplayText.oneLine(editor, limit: 200)) \(url.path)")
                guard launchesApplications else { return }
                // (The system looks at the file and the application: on a thread of the kernel's own.)
                BlockingCalls.run {
                    NSWorkspace.shared.open(
                        [url],
                        withApplicationAt: Self.editorApplication(named: editor),
                        configuration: NSWorkspace.OpenConfiguration()
                    )
                }
            }
        )
        // `.text`: the editor's name, path or bundle identifier; `.location`: the application;
        // without, the user picks it.
        commands.register(
            Command(Self.chooseEditor, "Choose Editor for F4…", runsDuringJobs: true),
            parameterized: { [self] argument in
                guard
                    let editor = argument.text ?? argument.location?.path
                        ?? chooseApplication(title: "Choose the editor for F4")?.path
                else { return }
                kernel.settings.set(editor, forKey: Self.editorKey)
            }
        )

        commands.register(
            Command(Self.openWithDefault, "Open with Default Application", runsDuringJobs: true),
            enabled: { cursorItem() != nil }
        ) { [self] in
            // Offered only on a local item.
            _ = cursorItem()
                .map { url in
                    remember("open \(url.path)")
                    open([url], with: nil)
                }
        }
        commands.register(
            Command(Self.openWith, "Open With…", runsDuringJobs: true),
            enabled: { cursorItem() != nil }
        ) { [self] in
            // Offered only on a local item.
            _ = cursorItem().map { url in openWith(url, in: kernel) }
        }
        commands.register(
            Command(.revealInFinder, "Reveal in Finder", [.cmd("r", .shift)], runsDuringJobs: true),
            enabled: { model().directory.isFileURL }
        ) { [self] in
            let directory = model().directory
            let launches = launchesApplications
            // Finder is shown the first items of a very large selection; it could not show more.
            withLocalOperands(of: model(), { Array($0.prefix(Self.revealLimit)) }) { [self] urls in
                // Without operands, the folder itself.
                let shown = urls.isEmpty ? [directory] : urls
                remember("reveal " + Self.described(shown))
                guard launches else { return }
                // Finder is asked away from the main thread: it looks at every file it is to select.
                BlockingCalls.run { NSWorkspace.shared.activateFileViewerSelecting(shown) }
            }
        }

        commands.register(
            Command(Self.quickLook, "Quick Look", [.cmd("y")], runsDuringJobs: true),
            enabled: hasLocalOperands,
            checked: { [self] in launchesApplications && quickLook.isVisible }
        ) { [self] in
            withLocalOperands(of: model(), { $0 }) { [self] urls in
                remember("quicklook " + Self.described(urls))
                followed = nil
                if launchesApplications { quickLook.toggle(urls) }
            }
        }
        // The open Quick Look panel follows the cursor and the active panel.
        subscription = kernel.panelEvents.subscribe { [weak self] _, panel in
            guard let self, launchesApplications, quickLook.isVisible, panel === kernel.panels.source else {
                return
            }
            follow(panel.model)
        }

        commands.register(
            Command(Self.share, "Share…", runsDuringJobs: true),
            enabled: hasLocalOperands
        ) { [self] in
            withLocalOperands(of: model(), { $0 }) { [self] urls in
                // The sharing panel looks at every item; nobody shares a hundred thousand at once.
                guard urls.count <= Self.shareLimit else {
                    return kernel.interaction.inform(
                        "Too many items to share",
                        detail: "\(urls.count) items are selected. "
                            + "At most \(Self.shareLimit) can be shared at a time.",
                        style: .warning
                    )
                }
                remember("share " + Self.described(urls))
                guard launchesApplications, let view = NSApp?.keyWindow?.contentView else { return }
                let picker = NSSharingServicePicker(items: urls)
                sharingPicker = picker
                picker.show(
                    relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1),
                    of: view,
                    preferredEdge: .minY
                )
            }
        }
        commands.register(Command(Self.editTags, "Finder Tags…"), enabled: hasLocalOperands) { [self] in
            withLocalOperands(of: model(), { $0 }) { [self] urls in editTags(of: urls, in: kernel) }
        }
        commands.register(
            Command(
                Self.copyAsPathname,
                "Copy as Pathname",
                [Shortcut(.character("c"), [.command, .option])],
                runsDuringJobs: true
            ),
            enabled: { model().directory.isFileURL }
        ) { [self] in
            let directory = model().directory
            // The paths of a large selection are put together off the main thread.
            withLocalOperands(
                of: model(),
                { urls in (urls.isEmpty ? [directory] : urls).map(\.path).joined(separator: "\n") }
            ) { [self] text in
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
        }

        let macSection = MenuSection(.files, order: 12)
        kernel.menus.add([.edit], to: .filesOpen)
        kernel.menus.add(
            [Self.openWith, Self.openWithDefault, Self.quickLook],
            to: macSection
        )
        kernel.menus.add(
            [
                .revealInFinder, Self.share, Self.editTags,
                Self.copyAsPathname
            ],
            to: .filesTools
        )
        kernel.menus.add([Self.chooseEditor], to: .configurationCustomize)
        kernel.menus.addToContextMenu([.edit], in: .open, onItemOnly: true)
        kernel.menus.addToContextMenu([.revealInFinder], in: .tools)
        kernel.menus.addToContextMenu(
            [
                Self.openWith, Self.quickLook, Self.share,
                Self.editTags, Self.copyAsPathname
            ],
            in: ContextMenuSection(order: 55),
            onItemOnly: true
        )
        kernel.toolbar.add(
            Self.quickLook,
            symbol: "eye",
            group: 60,
            hint: "Preview the selected file with macOS Quick Look."
        )
        kernel.toolbar.add(
            Self.share,
            symbol: "square.and.arrow.up",
            group: 60,
            hint: "Share the selected files: AirDrop, Mail, Messages and more."
        )
        kernel.toolbar.setSymbol("tag", for: Self.editTags)
        kernel.toolbar.setSymbol("arrow.up.forward.app", for: Self.openWith)
        kernel.toolbar.setSymbol("folder", for: .revealInFinder)
        kernel.toolbar.setSymbol("pencil", for: .edit)
        kernel.preferences.add(
            PreferencePage(
                title: "Edit (F4)",
                preferences: [
                    Preference(
                        Self.editorKey,
                        "Editor (application name, path or bundle identifier):",
                        .text(default: Self.defaultEditor)
                    )
                ]
            )
        )
    }

    public func stop() {
        subscription = nil
        if launchesApplications { quickLook.close() }
    }

    /// Lets the user pick the application that opens `url`: one of those that open it, or another.
    private func openWith(_ url: URL, in kernel: Kernel) {
        let applications = applications
        // Launch Services looks at the file to know what opens it; on a volume that has
        // stopped answering that never returns. It is asked in a job, which can be cancelled.
        kernel.jobs.run(
            title: "Applications:",
            work: { monitor -> [URL]? in
                BlockingCalls.answer(
                    from: Self.launchServices,
                    to: "applications " + url.path,
                    cancellation: monitor.cancellation
                ) { _ in applications(url) }
            },
            completion: { [self] found in
                guard let candidates = found else { return }
                let rows = candidates.enumerated()
                    .map {
                        Self.applicationName($0.element) + ($0.offset == 0 ? " (default)" : "")
                    }
                guard
                    let row = kernel.interaction.pickRow(
                        "Open “\(DisplayText.oneLine(url.lastPathComponent))” with",
                        rows: rows + ["Other…"],
                        button: "Open"
                    )
                else { return }
                guard
                    let application = candidates.indices.contains(row)
                        ? candidates[row]
                        : chooseApplication(title: "Choose an application")
                else { return }
                remember("open-with \(Self.applicationName(application)) \(url.path)")
                open([url], with: application)
            }
        )
    }

    /// Lets the user pick an application from the Applications folder. Never in tests.
    private func chooseApplication(title: String) -> URL? {
        guard launchesApplications else { return nil }
        let panel = NSOpenPanel()
        panel.title = title
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: Finder tags

    /// The Finder tags of a file. Reads the disk: not for the main thread.
    nonisolated static func tags(of url: URL) -> [String] {
        var value: AnyObject?
        try? (URL(fileURLWithPath: url.path) as NSURL).getResourceValue(&value, forKey: .tagNamesKey)
        return value as? [String] ?? []
    }

    /// Replaces the Finder tags of a file. Writes to the disk: not for the main thread.
    nonisolated static func setTags(_ tags: [String], of url: URL) throws {
        try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }

    /// The tags as the user types them: separated by commas, no empty ones, none twice.
    static func tags(from text: String) -> [String] {
        var tags: [String] = []
        for tag in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) })
        where !tag.isEmpty && !tags.contains(tag) {
            tags.append(tag)
        }
        return tags
    }

    /// Shows the tags of the first file and gives all files what the user makes of them. The
    /// disk is read and written as jobs, off the main thread.
    private func editTags(of urls: [URL], in kernel: Kernel) {
        guard let first = urls.first else { return }
        kernel.jobs.run(
            title: "Reading tags",
            work: { _ in Self.tags(of: first) },
            completion: { [self] current in
                let subject =
                    urls.count == 1 ? "“\(DisplayText.oneLine(first.lastPathComponent))”" : "\(urls.count) items"
                guard
                    let text = kernel.interaction.prompt(
                        "Finder tags of \(subject):",
                        value: current.joined(separator: ", "),
                        detail: "Separate tags with commas. An empty line removes all tags."
                    )
                else { return }
                let tags = Self.tags(from: text)
                kernel.jobs.run(
                    title: "Setting tags",
                    work: { monitor -> (error: any Error?, folders: [URL]) in
                        var failure: any Error?
                        for url in urls where !monitor.cancellation.isCancelled {
                            do { try Self.setTags(tags, of: url) } catch {
                                failure = error
                                break
                            }
                        }
                        // The folders to show again are worked out here, not on the main thread.
                        return (failure, Array(Set(urls.map { $0.deletingLastPathComponent() })))
                    },
                    completion: { [self] result in
                        if let error = result.error {
                            kernel.interaction.report(error, title: "The tags could not be set")
                        }
                        remember("tags " + Self.described(urls) + ": " + tags.joined(separator: ", "))
                        kernel.panels.refresh(result.folders)
                    }
                )
            }
        )
    }
}
