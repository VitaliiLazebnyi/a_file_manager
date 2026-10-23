import AFMContracts
public import AFMKernel
public import AppKit
import UniformTypeIdentifiers

/// What the Mac itself does with files: opening them with their application or one the user
/// picks, editing in the editor of the user's choice, Quick Look, sharing, Finder tags, showing
/// them in Finder (spec 10 › Associations, 10 › Edit (F4), 05 › File and folder context menu).
///
/// Only files on the local disks can be handed to other applications.
///
/// Thread ownership: the plugin's state and its commands belong to the main thread; looking
/// for applications, reading or writing tags, and picking the marked items out of a long list
/// happen in the background.
public final class MacIntegrationPlugin: Plugin {
    /// Stands for Launch Services in `BlockingCalls`: used for nothing but what object it is.
    private final class LaunchServices: Sendable {
        deinit {
            // Nothing to release.
        }
    }

    /// What the open Quick Look panel was given last: the panel's list and marks then.
    internal struct Followed: Equatable {
        /// The panel's list model.
        internal let model: ObjectIdentifier
        /// How many items were marked.
        internal let marked: Int
        /// The version of the list then.
        internal let listVersion: Int
    }

    /// The kernel's source panel as the commands see it, held without keeping the kernel.
    ///
    /// The kernel keeps what is registered with it; a command that kept the kernel in turn would
    /// keep both alive. Main thread only.
    @MainActor
    internal struct SourcePanel {
        /// The kernel the plugin was started in.
        internal unowned let kernel: Kernel

        /// The list of the source panel now.
        internal var model: PanelModel { kernel.panels.source.model }

        /// The local file under the cursor; nil on a folder or on a file elsewhere.
        internal var cursorFile: URL? { model.cursorFile.flatMap { $0.url.isFileURL ? $0.url : nil } }

        /// The local file or folder under the cursor; nil on an item elsewhere.
        internal var cursorItem: URL? { model.cursorItem.flatMap { $0.url.isFileURL ? $0.url : nil } }

        /// Whether there is something local to act on.
        ///
        /// The cheap test for the toolbar, which asks ten times a second: the list of operands can
        /// be a whole folder and is made only when a command runs.
        internal var hasLocalOperands: Bool {
            let panel = model
            return panel.hasOperands && (panel.directory.isFileURL || panel.cursorItem?.url.isFileURL == true)
        }
    }

    /// Both lists are kept to this length; a program that runs for weeks must not grow with every click.
    private static let recordLimit = 256

    /// From this many marked items on, they are picked out off the main thread.
    internal static let backgroundListThreshold = 5_000
    /// The most items Finder is asked to select at a time.
    nonisolated internal static let revealLimit = 1_000
    /// The most items that are shared at a time.
    internal static let shareLimit = 1_000

    /// The preference that names the editor for F4: an application's name, its path, or its
    /// bundle identifier.
    public static let editorKey = "macIntegration.editor"
    /// The editor F4 starts until the user chooses another.
    public static let defaultEditor = "TextEdit"

    /// Opens the file under the cursor with an application the user picks from a list.
    public static let openWith: CommandID = "afm_OpenWith"
    /// Opens the item under the cursor with its default application.
    public static let openWithDefault: CommandID = "afm_OpenWithDefault"
    /// Sets the editor of F4: from the argument, or picked by the user.
    public static let chooseEditor: CommandID = "afm_ChooseEditor"
    /// Shows or closes the Quick Look panel for the operands.
    public static let quickLook: CommandID = "afm_QuickLook"
    /// Shows the system's sharing panel for the operands.
    public static let share: CommandID = "afm_Share"
    /// Edits the Finder tags of the operands.
    public static let editTags: CommandID = "afm_EditTags"
    /// Copies the paths of the operands, one per line, or the folder's own.
    public static let copyAsPathname: CommandID = "afm_CopyAsPathname"

    /// The plugin's name in the list of plugins.
    public let name = "Mac integration"
    /// Where requests to other applications and the system's panels go: the Mac's desktop, a
    /// test's recording one, or nowhere (tests that start nothing).
    ///
    /// What would have been opened is recorded in `opened` and `log` either way.
    internal let desktop: (any MacDesktop)?
    /// Where Copy as Pathname puts the paths: the general pasteboard, or a test's own.
    internal let pasteboard: NSPasteboard
    private let applications: @Sendable (URL) -> [URL]
    /// The files most recently handed to an application (or that would have been); for tests.
    public private(set) var opened: [URL] = []
    /// What was done, one line each, the most recent ones: `edit TextEdit /a/b.txt`,
    /// `open-with Preview /a/c.png`, `open /a/d`, `quicklook /a/e`, `share /a/f`, `tags /a/g: Red, Work`.
    public private(set) var log: [String] = []

    /// What the open Quick Look panel was given last; nil while it follows the cursor.
    private var followed: Followed?
    private var followTicket = 0
    private let quickLook = QuickLookController()
    /// Who asks Launch Services which applications open a file: stands for it in `BlockingCalls`.
    private let launchServices = LaunchServices()
    private var subscription: AnyObject?

    /// Tests pass a pasteboard of their own and say which applications open a file; with
    /// `launchesApplications` off they start nothing and show no system panel.
    @preconcurrency
    public convenience init(
        launchesApplications: Bool = true,
        pasteboard: NSPasteboard = .general,
        applications: (@Sendable (URL) -> [URL])? = nil
    ) {
        self.init(
            desktop: launchesApplications ? SystemDesktop() : nil,
            pasteboard: pasteboard,
            applications: applications ?? { Self.installedApplications(for: $0) }
        )
    }

    /// A plugin that hands its requests to `desktop`.
    internal init(
        desktop: (any MacDesktop)?,
        pasteboard: NSPasteboard,
        applications: @escaping @Sendable (URL) -> [URL]
    ) {
        self.desktop = desktop
        self.pasteboard = pasteboard
        self.applications = applications
        quickLook.panel = desktop?.preview
    }

    /// The files of a log line: their paths while they are few, their number when they are
    /// many (a line with every path of a large selection would be megabytes).
    internal static func described(_ urls: [URL]) -> String {
        urls.count <= 8 ? urls.map(\.path).joined(separator: " ") : "\(urls.count) items"
    }

    /// The name of an application, without `.app`.
    private static func applicationName(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    /// Registers the opener, the commands, their menus and the preference page; main thread.
    public func start(in owner: Kernel) {
        let source = SourcePanel(kernel: owner)
        // The system's Quick Look panel keeps the file it previews: it closes before the drive is ejected.
        owner.fileSystems.addVolumeReleaser { [weak self] volume in self?.quickLook.close(ifShowing: volume) }
        registerEditCommands(source)
        registerOpenCommands(source)
        registerQuickLook(source)
        registerShareCommands(source)
        Self.addMenus(in: owner)
    }

    /// Stops following the panels and closes the Quick Look panel.
    public func stop() {
        subscription = nil
        quickLook.close()
    }

    /// Records files handed to an application, the most recent ones.
    internal func remember(opened urls: [URL]) {
        opened = Array((opened + urls).suffix(Self.recordLimit))
    }

    /// A line of the log.
    ///
    /// Names come from the disk: a line break in one cannot make a second line.
    internal func remember(_ line: String) {
        log.append(DisplayText.oneLine(line, limit: 2_000))
        if log.count > Self.recordLimit * 2 {
            log.removeFirst(log.count - Self.recordLimit)
        }
    }

    /// The local operands of a panel, worked on by `work` and handed to `deliver` on the main
    /// thread.
    ///
    /// With many marked items both happen on a background thread first (the marks and the list are
    /// taken as they are, which copies nothing); with few, everything is done at once, here.
    /// `deliver` runs from the main run loop, not from a block of the main queue: it may ask the
    /// user something.
    internal func withLocalOperands<Result: Sendable>(
        of model: PanelModel,
        _ work: @escaping @Sendable ([URL]) -> Result,
        then deliver: @escaping @MainActor @Sendable (Result) -> Void
    ) {
        let operands = model.operandsSnapshot()
        @Sendable
        func urls() -> [URL] { operands.items().map(\.url).filter(\.isFileURL) }
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

    /// Has the open Quick Look panel show what the source panel now has.
    ///
    /// A move of the cursor costs nothing that grows with the list: without marked items the file
    /// under the cursor is shown, and with them the panel keeps showing those until they or the
    /// list change.
    private func follow(_ model: PanelModel) {
        let marked = model.selectionCount
        let state = Followed(model: ObjectIdentifier(model), marked: marked, listVersion: model.listVersion)
        guard marked > 0 else {
            followed = nil
            followTicket += 1
            quickLook.follow(model.cursorItem.flatMap { $0.url.isFileURL ? [$0.url] : nil } ?? [])
            return
        }
        if followed == state {
            return
        }
        followed = state
        followTicket += 1
        let ticket = followTicket
        withLocalOperands(
            of: model,
            { $0 },
            then: { [weak self] urls in
                // Something newer is being shown by now.
                guard let self, followTicket == ticket, quickLook.isVisible else {
                    return
                }
                quickLook.follow(urls)
            }
        )
    }

    /// Hands files to `application`, or each to its own default application without one.
    internal func open(_ urls: [URL], with application: URL?) {
        remember(opened: urls)
        guard let desktop else {
            return
        }
        if let application {
            desktop.open(urls, with: application)
        } else {
            // Launch Services answers each file in its own time; none of them holds up the main thread.
            for url in urls {
                desktop.open(url)
            }
        }
    }

    /// Lets the user pick the application that opens `url`: one of those that open it, or another.
    internal func openWith(_ url: URL, in kernel: Kernel) {
        let lookUp = applications
        let asker = launchServices
        // Launch Services looks at the file to know what opens it; on a volume that has
        // stopped answering that never returns. It is asked in a job, which can be cancelled.
        kernel.jobs.run(
            title: "Applications:",
            work: { monitor -> Result<[URL], CancellationError> in
                let found = BlockingCalls.answer(
                    from: asker,
                    to: "applications " + url.path,
                    cancellation: monitor.cancellation
                ) { _ in lookUp(url) }
                return found.map { .success($0) } ?? .failure(CancellationError())
            },
            completion: { [self] search in
                guard case .success(let candidates) = search else {
                    return
                }
                let rows = candidates.enumerated()
                    .map { index, application in
                        Self.applicationName(application) + (index == 0 ? " (default)" : "")
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

    /// Lets the user pick an application from the Applications folder; nil without a desktop.
    internal func chooseApplication(title: String) -> URL? {
        desktop?.chooseApplication(title: title)
    }

    /// Shows the system's sharing panel for `urls`, unless there are too many.
    internal func share(_ urls: [URL], in kernel: Kernel) {
        // The sharing panel looks at every item; nobody shares a hundred thousand at once.
        guard urls.count <= Self.shareLimit else {
            kernel.interaction.inform(
                "Too many items to share",
                detail: "\(urls.count) items are selected. At most \(Self.shareLimit) can be shared at a time.",
                style: .warning
            )
            return
        }
        remember("share " + Self.described(urls))
        // At the middle of the window that has the keyboard; none has it when the program went to
        // the background while a long list was gone through, and then nothing is shown.
        guard let desktop, let view = desktop.keyWindowContent else {
            return
        }
        desktop.share(urls, at: view)
    }

    /// Quick Look, and the open panel following the cursor and the active panel.
    private func registerQuickLook(_ source: SourcePanel) {
        source.kernel.commands.register(
            Command(Self.quickLook, "Quick Look", [.cmd("y")], runsDuringJobs: true),
            enabled: { source.hasLocalOperands },
            checked: { [self] in quickLook.isVisible },
            { [self] in
                // The panel looks for its feeder in the responder chain of the window the command came
                // from: joined now, while that window is the main one. A long list is gone through
                // first, and by then the program may be in the background, without a main window.
                quickLook.join(desktop?.mainWindow)
                withLocalOperands(
                    of: source.model,
                    { $0 },
                    then: { [self] urls in
                        remember("quicklook " + Self.described(urls))
                        followed = nil
                        quickLook.toggle(urls)
                    }
                )
            }
        )
        subscription = source.kernel.panelEvents.subscribe { [weak self] _, panel in
            guard let self, quickLook.isVisible, panel === source.kernel.panels.source else {
                return
            }
            follow(panel.model)
        }
    }

    deinit {
        // Nothing to release.
    }
}
