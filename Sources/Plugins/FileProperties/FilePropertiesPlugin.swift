import AFMContracts
public import AFMKernel
public import Foundation

/// Commands only this plugin provides (spec 17 › Command catalogue).
extension CommandID {
    static let editComment: CommandID = "cm_EditComment"
    static let createShortcut: CommandID = "cm_CreateShortcut"
    /// Calculates the size of every folder of the source panel (Alt+Shift+Enter).
    static let countDirectoryContents: CommandID = "cm_CountDirContent"
    static let showLinkTarget: CommandID = "afm_ShowLinkTarget"
    static let finderInfo: CommandID = "afm_FinderInfo"
}

/// Attributes, properties, occupied space, comments and links (spec 07 › Change attributes,
/// File comments, Properties, Calculate occupied space, Create shortcut), and the columns
/// that show such facts in the file list.
public final class FilePropertiesPlugin: Plugin {
    public let name = "FileProperties"
    /// Runs AppleScript with these `osascript` arguments; nil starts nothing (tests).
    private let runScript: (@Sendable ([String]) -> Void)?
    /// The items Finder's Info window was asked for, whether or not Finder was really told; the
    /// most recent ones only, for tests to look at.
    public private(set) var finderInfoRequests: [URL] = []
    private static let finderInfoRequestLimit = 64

    enum Settings {
        static let linkKind = "fileProperties.linkKind"
        static let relativeLinks = "fileProperties.relativeLinks"
        static let selectMeasured = "fileProperties.selectMeasuredFolders"
        static let hideCommentFile = "fileProperties.hideCommentFile"
    }

    /// Tests turn `launchesApplications` off, so they do not start other applications.
    public convenience init(launchesApplications: Bool = true) {
        self.init(runScript: launchesApplications ? AppleScript.run : nil)
    }

    /// A plugin that hands its AppleScript to `runScript`.
    init(runScript: (@Sendable ([String]) -> Void)?) {
        self.runScript = runScript
    }

    public func start(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        let comments = CommentStore(fileSystems: kernel.fileSystems)
        PropertyColumns.register(in: kernel.columns, comments: comments)
        let actions = PropertyActions(kernel, comments: comments) { [weak self] urls in self?.showFinderInfo(urls) }

        let commands = kernel.commands
        let model = { kernel.panels.source.model }
        let hasOperands = { model().hasOperands }
        let isWritable = { kernel.fileSystems.capabilities(for: model().directory).contains(.write) }
        let isLocal = { model().directory.isFileURL }

        commands.register(
            Command(.setAttributes, "Change Attributes…"),
            enabled: { hasOperands() && isWritable() },
            parameterized: actions.changeAttributes
        )
        commands.register(
            Command(.properties, "Properties…", [Shortcut(.returnKey, .option), .cmd("i")]),
            enabled: { model().isListed },
            actions.showProperties
        )
        commands.register(
            Command(.occupiedSpace, "Calculate Occupied Space…", [Shortcut(.character("l"), .control)]),
            enabled: hasOperands,
            actions.calculateOccupiedSpace
        )
        commands.register(
            Command(
                .countDirectoryContents,
                "Calculate All Folder Sizes",
                [Shortcut(.returnKey, [.option, .shift])]
            ),
            enabled: { model().isComplete && model().totals.totalFolders > 0 },
            actions.countDirectoryContents
        )
        commands.register(
            Command(.editComment, "Edit Comment…", [Shortcut(.character("z"), .control)]),
            enabled: { isWritable() && (model().cursorItem != nil || model().parentTarget != nil) },
            actions.editComment
        )
        commands.register(
            Command(.createShortcut, "Create Link…", [.f(5, [.control, .shift])]),
            enabled: { hasOperands() && isLocal() },
            actions.createLinks
        )
        commands.register(
            Command(.showLinkTarget, "Show Link Target"),
            enabled: { model().cursorItem?.url.isFileURL ?? false }
        ) {
            _ = model().cursorItem.map(actions.showLinkTarget)
        }
        commands.register(
            Command(.finderInfo, "Finder Info", runsDuringJobs: true),
            enabled: { isLocal() && model().isListed }
        ) {
            // Finder opens one window per item: more than a handful is never meant, and the
            // list of a long selection is not made for it.
            let operands = model().operandsSnapshot()
            var urls: [URL] = []
            if operands.markedCount > Self.finderInfoRequestLimit {
                for index in operands.shownItems.indices where operands.isMarked(at: index) {
                    urls.append(operands.shownItems[index].url)
                    if urls.count == Self.finderInfoRequestLimit { break }
                }
            } else {
                urls = operands.items().map(\.url)
            }
            actions.showFinderInfo(urls.isEmpty ? [model().directory] : urls)
        }

        kernel.menus.add(
            [.setAttributes, .properties, .finderInfo, .occupiedSpace, .countDirectoryContents, .editComment],
            to: .filesProperties
        )
        kernel.menus.add([.createShortcut, .showLinkTarget], to: .filesAdvanced)
        kernel.menus.addToContextMenu(
            [.setAttributes, .editComment, .createShortcut],
            in: .properties,
            onItemOnly: true
        )
        kernel.menus.addToContextMenu([.occupiedSpace, .properties], in: .properties)
        kernel.toolbar.add(
            .properties,
            symbol: "info.circle",
            group: 60,
            hint: "Show the properties of the selected file or folder: size, dates, permissions."
        )
        kernel.toolbar.add(
            .occupiedSpace,
            symbol: "chart.pie",
            group: 60,
            hint: "Calculate how much space the selected folders take, with everything in them."
        )
        kernel.toolbar.setSymbol("slider.horizontal.3", for: .setAttributes)
        kernel.toolbar.setSymbol("text.bubble", for: .editComment)
        kernel.toolbar.setSymbol("link", for: .createShortcut)

        kernel.preferences.add(
            PreferencePage(
                title: "File properties",
                preferences: [
                    Preference(
                        Settings.linkKind,
                        "Create Link proposes:",
                        .choice(LinkKind.allCases.map(\.title), default: LinkKind.symbolic.rawValue)
                    ),
                    Preference(
                        Settings.relativeLinks,
                        "Symbolic links point to relative paths",
                        .flag(default: false)
                    ),
                    Preference(
                        Settings.selectMeasured,
                        "Calculate Occupied Space selects the measured folders",
                        .flag(default: true)
                    ),
                    Preference(Settings.hideCommentFile, "Hide the comment file descript.ion", .flag(default: true))
                ]
            )
        )
    }

    /// Opens Finder's Info window for local items. Finder is asked through `osascript`, off
    /// the main thread; the first time, macOS asks the user whether the program may control
    /// Finder.
    /// Asked for local items only: the command is offered in local folders, the button of the
    /// Properties dialog for local items.
    private func showFinderInfo(_ urls: [URL]) {
        finderInfoRequests = Array((finderInfoRequests + urls).suffix(Self.finderInfoRequestLimit))
        guard let runScript else { return }
        let arguments = Self.finderInfoArguments(urls)
        // Starting a program waits for the system: on a thread for work that waits.
        BlockingCalls.run { runScript(arguments) }
    }

    /// The `osascript` arguments that open Finder's Info window of each item.
    static func finderInfoArguments(_ urls: [URL]) -> [String] {
        let script = [
            "on run paths", "tell application \"Finder\"", "repeat with itemPath in paths",
            "open information window of ((POSIX file (contents of itemPath)) as alias)", "end repeat", "activate",
            "end tell", "end run"
        ]
        return script.flatMap { ["-e", $0] } + urls.map(\.path)
    }
}

/// The behaviour behind the commands.
///
/// **Threading.** Commands start on the main thread and only prepare there: they read the
/// panel's state and ask the user. Whatever touches a file system, even to pre-fill a dialog,
/// runs inside a job on the job's thread; the completion returns to the main thread to show
/// the result and refresh the panels.
@MainActor
final class PropertyActions {
    /// Unowned: the kernel owns the plugin, and through it this.
    private unowned let kernel: Kernel
    private let comments: CommentStore
    let showFinderInfo: ([URL]) -> Void

    init(_ kernel: Kernel, comments: CommentStore, showFinderInfo: @escaping ([URL]) -> Void) {
        self.kernel = kernel
        self.comments = comments
        self.showFinderInfo = showFinderInfo
    }

    private var source: any PanelHandle { kernel.panels.source }
    private var ui: any UserInteraction { kernel.interaction }
    private var fileSystems: FileSystemRegistry { kernel.fileSystems }

    /// The folders whose listings an operation on `items` may have changed. Grows with the
    /// selection, so it is worked out on a job's thread.
    nonisolated private static func folders(of items: [FileItem], and directory: URL) -> [URL] {
        var seen = Set<String>()
        return ([directory] + items.map { $0.url.deletingLastPathComponent() })
            .filter {
                seen.insert($0.locationKey).inserted
            }
    }

    /// The first failures of an operation as the text of a message: a message is laid out
    /// whole, and one line per item of a large selection would be megabytes of it.
    static func summary(of failures: [String], total: Int? = nil, limit: Int = 20) -> String {
        let count = total ?? failures.count
        let shown = failures.prefix(limit)
        return shown.joined(separator: "\n") + (count > shown.count ? "\n… and \(count - shown.count) more" : "")
    }

    // MARK: Change attributes

    /// `.text`: parameters as `AttributeChange.parse` reads them; without, the dialog.
    func changeAttributes(_ argument: CommandArgument) {
        let model = source.model
        // What is marked is noted here at no cost; the list of it is made on the job's thread
        // (for a selection of several hundred thousand that is time the main thread does not have).
        // Offered only where there are operands.
        let (operands, directory) = (model.operandsSnapshot(), model.directory)
        var parsed: (change: AttributeChange, applyAtOnce: Bool)?
        if let text = argument.text {
            guard let read = AttributeChange.parse(parameters: text) else {
                ui.inform("The attribute parameters cannot be read!", detail: text, style: .warning)
                return
            }
            parsed = (read.change, read.applyAtOnce)
        }
        // The current flags and owner of a single item are shown in the dialog; reading them
        // is a question to the disk, and turning the owner's number into a name may be one
        // to a directory server. Both are asked here; the dialog then finds the names known.
        let asksAtOnce = parsed?.applyAtOnce == true
        kernel.jobs.run(
            title: "Reading attributes:",
            work: { _ -> (items: [FileItem], details: LocalDetails?) in
                let items = operands.items()
                guard !asksAtOnce, items.count == 1, let details = LocalInfo.details(items[0].url) else {
                    return (items, nil)
                }
                _ = (LocalInfo.userName(details.ownerID), LocalInfo.groupName(details.groupID))
                return (items, details)
            },
            completion: { [self] read in
                let items = read.items
                if let parsed, parsed.applyAtOnce { return apply(parsed.change, to: items, in: directory) }
                // The panel may show something else by now; a dialog about what it showed would mislead.
                guard model.directory.isSameLocation(as: directory) else { return }
                var draft = AttributeDraft(items: items)
                if let parsed { draft.take(parsed.change) }
                ask(draft, items: items, directory: directory, details: read.details)
            }
        )
    }

    private func ask(_ draft: AttributeDraft, items: [FileItem], directory: URL, details: LocalDetails?) {
        var draft = draft
        let isLocal = items.allSatisfy { $0.url.isFileURL }
        let title = "Change attributes: " + (items.count == 1 ? items[0].name : String(items.count))
        let targetFile = kernel.panels.target.model.cursorItem
        let buttons = ["OK"] + (targetFile != nil ? ["Load from Target File"] : [])
        // Asked until the answer can be applied or the dialog is cancelled.
        while let answer = ui.form(
            title,
            detail: "",
            fields: draft.fields(isLocal: isLocal, details: details),
            buttons: buttons
        ) {
            draft.read(answer)
            if answer.button == 1, let targetFile {
                // Load from file under cursor › From target (spec 07 › Load from file under cursor).
                draft.load(from: targetFile)
                continue
            }
            switch draft.change(isLocal: isLocal) {
            case .failure(let problem):
                ui.inform(problem.message, detail: "", style: .warning)

            case .success(let change):
                // Recurse with the permissions left as they were shown asks for nothing: the
                // field shows the folder's own mode, not a wish. Said, instead of ending silently.
                if change.isEmpty, draft.recurse, let shown = draft.untouchedPermissions {
                    let applies =
                        ui.choose(
                            "Nothing was changed.",
                            detail: "Do you want to give the permissions \(shown) to everything inside as well?",
                            buttons: ["Apply \(shown)", "Back"],
                            style: .warning
                        ) == 0
                    if applies { draft.confirmPermissions() }
                    continue
                }
                apply(change, to: items, in: directory)
                return
            }
        }
    }

    private func apply(_ change: AttributeChange, to items: [FileItem], in directory: URL) {
        guard !change.isEmpty else { return }
        let model = source.model
        model.saveSelection()
        let fileSystems = self.fileSystems
        let title = "Changing attributes:"
        kernel.jobs.run(
            title: title,
            work: { monitor -> (AttributeJob.Outcome, [URL]) in
                let meter = ProgressMeter(monitor, title: title, total: change.recurse ? 0 : items.count)
                let outcome = AttributeJob(
                    change: change,
                    fileSystems: fileSystems,
                    cancellation: monitor.cancellation,
                    meter: meter
                )
                .run(items)
                return (outcome, Self.folders(of: items, and: directory))
            },
            completion: { [self] outcome, folders in
                if outcome.failed > 0 {
                    ui.inform(
                        "\(outcome.failed) item(s) could not be changed!",
                        detail: Self.summary(of: outcome.failures, total: outcome.failed),
                        style: .warning
                    )
                }
                kernel.panels.refresh(folders)
            }
        )
    }

    // MARK: Properties

    /// The item under the cursor, the selection when it holds several items, or on `[..]` the
    /// folder the panel shows.
    func showProperties() {
        let model = source.model
        let directory = model.directory
        // (The list of a long selection is made on the job's thread.)
        let operands = model.operandsSnapshot()
        let cursorItem = model.cursorItem
        let (fileSystems, comments) = (self.fileSystems, self.comments)
        let title = "Properties:"
        kernel.jobs.run(
            title: title,
            work: { monitor -> (name: String, rows: [PropertyRow], urls: [URL]) in
                let sheet = PropertySheet(
                    fileSystems: fileSystems,
                    comments: comments,
                    cancellation: monitor.cancellation,
                    meter: ProgressMeter(monitor, title: title)
                )
                let selected = operands.markedCount > 1 ? operands.markedItems() : []
                if !selected.isEmpty {
                    return ("\(selected.count) items", sheet.rows(forSeveral: selected), selected.map(\.url))
                }
                guard
                    let item = cursorItem
                        ?? (try? fileSystems.provider(for: directory))?
                        .item(
                            at: directory,
                            cancellation: monitor.cancellation
                        )
                else {
                    return (directory.lastPathComponent, [], [])
                }
                return (
                    item.name.isEmpty ? fileSystems.displayPath(item.url) : item.name, sheet.rows(for: item),
                    [item.url]
                )
            },
            completion: { [self] report in
                guard !report.rows.isEmpty else {
                    return ui.inform(
                        "The properties of \(PropertyText.shown(report.name)) cannot be read!",
                        detail: "",
                        style: .warning
                    )
                }
                let canShowFinderInfo = report.urls.allSatisfy(\.isFileURL)
                let answer = ui.form(
                    "Properties: \(report.name)",
                    detail: "",
                    fields: report.rows.map { .note("\($0.label): \($0.value)") },
                    buttons: ["OK"] + (canShowFinderInfo ? ["Finder Info"] : [])
                )
                if answer?.button == 1 { showFinderInfo(report.urls) }
            }
        )
    }

    // MARK: Occupied space

    func calculateOccupiedSpace() {
        let model = source.model
        // The list of the operands is made on the job's thread, and so is everything that
        // grows with it: the sum, which folders were measured, whether all of it is local.
        let (operands, directory, basis) = (model.operandsSnapshot(), model.directory, model.basis)
        let targetDirectory = kernel.panels.target.model.directory
        // Offered only where there are operands.
        let fileSystems = self.fileSystems
        let title = "Calculating occupied space:"
        struct Result {
            var totals = SpaceTotals()
            /// The folders that were measured, with their sizes, and their names.
            var sizes: [(name: String, size: Int64)] = []
            /// The sizes written into a copy of the list, for the model to take in one step.
            var prepared: PanelModel.Prepared?
            var isLocal = true
            var targetCluster: Int64?
            var volume: VolumeInfo?
            var cancelled = false
        }
        kernel.jobs.run(
            title: title,
            work: { monitor -> Result in
                var result = Result()
                let items = operands.items()
                result.targetCluster = LocalInfo.clusterSize(at: targetDirectory)
                let calculator = SpaceCalculator(
                    fileSystems: fileSystems,
                    cancellation: monitor.cancellation,
                    targetCluster: result.targetCluster,
                    meter: ProgressMeter(monitor, title: title)
                )
                let perItem = calculator.measure(items)
                result.totals = perItem.reduce(SpaceTotals(), +)
                for (item, measured) in zip(items, perItem) where item.isFolder && item.isRealDirectory {
                    result.sizes.append((item.name, measured.bytes))
                }
                result.isLocal = items.allSatisfy { $0.url.isFileURL }
                if !monitor.cancellation.isCancelled, !result.sizes.isEmpty {
                    result.prepared = PanelModel.prepare(basis, computedSizes: result.sizes)
                }
                result.volume = (try? fileSystems.provider(for: directory))?
                    .volume(
                        of: directory,
                        cancellation: monitor.cancellation
                    )
                result.cancelled = monitor.cancellation.isCancelled
                return result
            },
            completion: { [self] result in
                if !result.cancelled, model.directory.isSameLocation(as: directory) {
                    // A measured folder shows its size in the Size column and is drawn as selected.
                    // One change for all of them: each is a search of the list and a redraw.
                    let selects = kernel.settings.flag(FilePropertiesPlugin.Settings.selectMeasured, default: true)
                    Self.show(result.sizes, prepared: result.prepared, in: model)
                    if selects { model.setSelected(true, names: result.sizes.map(\.name)) }
                }
                ui.inform(
                    "Total space occupied:",
                    detail: SpaceReport.text(
                        result.totals,
                        sourceIsLocal: result.isLocal,
                        targetCluster: result.targetCluster,
                        volume: result.volume,
                        cancelled: result.cancelled
                    ),
                    style: .information
                )
            }
        )
    }

    /// The size of every folder of the source panel, shown in the Size column
    /// (spec 03 › Counting rules, `cm_CountDirContent`).
    func countDirectoryContents() {
        let model = source.model
        let directory = model.directory
        // The list is looked through on the job's thread: it may be a million entries long.
        let (shown, basis) = (model.items, model.basis)
        let fileSystems = self.fileSystems
        let title = "Calculating folder sizes:"
        kernel.jobs.run(
            title: title,
            work: { monitor -> (sizes: [(name: String, size: Int64)], prepared: PanelModel.Prepared?) in
                let folders = shown.filter { $0.isFolder && $0.isRealDirectory }
                let measured = SpaceCalculator(
                    fileSystems: fileSystems,
                    cancellation: monitor.cancellation,
                    meter: ProgressMeter(monitor, title: title),
                    measuresAllocated: false
                )
                .measure(folders)
                let sizes = zip(folders, measured).map { (name: $0.0.name, size: $0.1.bytes) }
                return (sizes, sizes.isEmpty ? nil : PanelModel.prepare(basis, computedSizes: sizes))
            },
            completion: { result in
                guard model.directory.isSameLocation(as: directory) else { return }
                Self.show(result.sizes, prepared: result.prepared, in: model)
            }
        )
    }

    /// Shows calculated folder sizes in a panel. They were written into a copy of the list on
    /// the job's thread (`prepared`), which the model takes in one step; if its list is no
    /// longer the one the copy was made of, the sizes are set by name instead. Main thread.
    static func show(_ sizes: [(name: String, size: Int64)], prepared: PanelModel.Prepared?, in model: PanelModel) {
        guard !sizes.isEmpty else { return }
        if let prepared, model.apply(prepared) != .stale { return }
        model.setComputedSizes(sizes)
    }

    // MARK: Comments

    /// Edits the comment of the item under the cursor; on `[..]`, of the folder the panel
    /// shows, whose comment is kept in the folder above (spec 07 › File comments).
    func editComment() {
        let model = source.model
        // Offered on an item, or on `[..]` of a folder that has a parent to keep its comment.
        let subject = model.cursorItem?.url ?? model.directory
        let (name, folder) = (subject.lastPathComponent, subject.deletingLastPathComponent())
        let comments = self.comments
        let directory = model.directory
        kernel.jobs.run(
            title: "Reading comment:",
            work: { monitor -> String? in
                let text = comments.load(folder, cancellation: monitor.cancellation).comment(for: name) ?? ""
                // A reading that was stopped says nothing; the dialog must not show "no comment".
                return monitor.cancellation.isCancelled ? nil : text
            },
            completion: { [self] read in
                guard let existing = read else { return }
                // Asked for in a folder the panel no longer shows: the dialog would come out of nowhere.
                guard model.directory.isSameLocation(as: directory) else { return }
                var text = existing
                while true {
                    guard
                        let answer = ui.form(
                            "File comment",
                            detail: "Edit comment for:\n\(PropertyText.shown(name))",
                            fields: [.lines("comment", "", text)],
                            buttons: ["OK"]
                        )
                    else { return }
                    text = DescriptIon.normalized(answer.text("comment"))
                    // A line break counts two characters, as it does in the file.
                    let length = text.count + text.filter { $0 == "\n" }.count
                    if length <= DescriptIon.commentLimit { break }
                    ui.inform(
                        "The comment is too long!",
                        detail: "It has \(length) characters; \(DescriptIon.commentLimit) can be stored.",
                        style: .warning
                    )
                }
                guard text != existing else { return }
                save(text, for: name, in: folder)
            }
        )
    }

    private func save(_ comment: String, for name: String, in folder: URL) {
        let comments = self.comments
        let hidden = kernel.settings.flag(FilePropertiesPlugin.Settings.hideCommentFile, default: true)
        kernel.jobs.run(
            title: "Saving comment:",
            work: { monitor -> any Error? in
                do {
                    try comments.setComment(
                        comment,
                        for: name,
                        in: folder,
                        hidden: hidden,
                        cancellation: monitor.cancellation
                    )
                    return nil
                } catch {
                    return error
                }
            },
            completion: { [kernel] error in
                // Stopped by the user: the old comments are as they were, and there is nothing to tell.
                if (error as? CocoaError)?.code == .userCancelled { return }
                if let error {
                    return kernel.interaction.report(
                        error,
                        title: "The comment of \(PropertyText.shown(name)) cannot be saved!"
                    )
                }
                // Saving a comment re-reads both panels.
                kernel.panels.contentsChanged(in: [folder])
                kernel.panels.all.forEach { $0.reload() }
            }
        )
    }

    // MARK: Links

    /// Creates links to the operands, by default in the target panel's folder
    /// (spec 07 › Create shortcut).
    func createLinks() {
        let model = source.model
        // The dialog needs how many items there are and, for one, its name; the list of a
        // long selection is made on the job's thread.
        // Offered only where there are operands: the marked ones, or the item under the cursor.
        let (operands, directory) = (model.operandsSnapshot(), model.directory)
        let count = max(operands.markedCount, 1)
        let single = count == 1 ? operands.items().first : nil
        let settings = kernel.settings
        let targetPath = fileSystems.displayPath(kernel.panels.target.model.directory)
        let proposal = (targetPath.hasSuffix("/") ? targetPath : targetPath + "/") + (single?.name ?? "")
        let detail = single.map { "Create a link to \"\($0.name)\" as:" } ?? "Create links to \(count) items in:"
        let kinds = LinkKind.allCases
        guard
            let answer = ui.form(
                "Create link",
                detail: detail,
                fields: [
                    .text("target", "", proposal),
                    .choice(
                        "kind",
                        "Type:",
                        kinds.map(\.title),
                        selected: settings.index(FilePropertiesPlugin.Settings.linkKind, default: 0)
                    ),
                    .checkbox(
                        "relative",
                        "Symbolic link with a relative path",
                        settings.flag(FilePropertiesPlugin.Settings.relativeLinks, default: false)
                    )
                ],
                buttons: ["OK"]
            )
        else { return }
        let text = answer.text("target").trimmingCharacters(in: .whitespaces)
        let kind = kinds.indices.contains(answer.index("kind")) ? kinds[answer.index("kind")] : .symbolic
        let relative = answer.flag("relative")
        guard !text.isEmpty else { return }
        let fileSystems = self.fileSystems
        kernel.jobs.run(
            title: "Creating links:",
            work: { monitor -> (created: URL?, changed: [URL], failed: Int, failures: [String]) in
                let items = operands.items()
                let location = fileSystems.location(from: text, relativeTo: directory)
                // A target that ends in a slash, or is a folder, or takes several links, is the
                // folder the links go into under the names of their originals.
                let isFolder =
                    text.hasSuffix("/") || items.count > 1
                    || (try? fileSystems.provider(for: location))?
                        .item(
                            at: location,
                            cancellation: monitor.cancellation
                        )?
                        .isDirectory == true
                // What the completion shows is put together here: the first failures only, and
                // each folder that got a link once.
                var (created, failed, failures): (URL?, Int, [String]) = (nil, 0, [])
                var (changed, seen): ([URL], Set<String>) = ([], [])
                for item in items where !monitor.cancellation.isCancelled {
                    // A branch view names an item by its path; the link gets the item's own name.
                    let destination = isFolder ? location.appending(name: item.url.lastPathComponent) : location
                    do {
                        try LinkMaker.create(kind, to: item.url, at: destination, relative: relative)
                        created = destination
                        let folder = destination.deletingLastPathComponent()
                        if seen.insert(folder.locationKey).inserted { changed.append(folder) }
                    } catch {
                        failed += 1
                        if failures.count < 20 {
                            failures.append("\(PropertyText.shown(item.name)): \(error.localizedDescription)")
                        }
                    }
                }
                return (created, changed, failed, failures)
            },
            completion: { [kernel] result in
                if result.failed > 0 {
                    kernel.interaction.inform(
                        "\(result.failed) link(s) could not be created!",
                        detail: Self.summary(of: result.failures, total: result.failed),
                        style: .warning
                    )
                }
                kernel.panels.refresh(result.changed, focus: result.created)
            }
        )
    }

    /// Goes to the item the link `item` (under the cursor) leads to, with the cursor on it.
    func showLinkTarget(_ item: FileItem) {
        let panel = source
        let directory = panel.model.directory
        kernel.jobs.run(
            title: "Reading link:",
            work: { _ in LocalInfo.resolvedLinkTarget(item.url) },
            completion: { [ui] target in
                // The answer belongs to the folder it was asked in; elsewhere it would take the panel away.
                guard panel.model.directory.isSameLocation(as: directory) else { return }
                guard let target else {
                    return ui.inform(
                        "\(PropertyText.shown(item.name)) is not a link.",
                        detail: "",
                        style: .information
                    )
                }
                panel.show(target)
            }
        )
    }
}

/// What the Change Attributes dialog holds while the user works on it: the texts as typed, so
/// that a mistake can be corrected without starting over.
struct AttributeDraft {
    struct Problem: Error {
        let message: String
    }

    private static let flagOptions = ["Unchanged", "Set", "Clear"]

    var recurse = false
    var permissions = ""
    /// What the permissions field was filled with. A field left as it was asks for no change:
    /// otherwise a change of the date alone would also set every file below a folder to the
    /// folder's own mode, and unlock a locked file.
    private var prefilledPermissions: String?

    /// The permissions as they were pre-filled, while the field still shows them.
    var untouchedPermissions: String? {
        guard let prefilled = prefilledPermissions, !prefilled.isEmpty,
            permissions.trimmingCharacters(in: .whitespaces) == prefilled
        else { return nil }
        return prefilled
    }

    /// What the field shows is meant after all (the user said so).
    mutating func confirmPermissions() {
        prefilledPermissions = nil
    }
    /// 0 unchanged, 1 set, 2 clear.
    var hidden = 0
    var locked = 0
    var owner = ""
    var group = ""
    var changesDate = false
    var usesCurrentTime = false
    var date = "yyyy-mm-dd"
    var time = "hh:mm:ss"

    /// One item shows its own permissions and date; several start with everything unchanged.
    init(items: [FileItem]) {
        guard items.count == 1 else { return }
        permissions = PropertyText.octal(items[0].permissions)
        prefilledPermissions = permissions
        (date, time) = TimestampChange.fieldTexts(for: items[0].modified)
    }

    /// Takes the permissions and the date of another file (Load from file under cursor); what
    /// is loaded is meant to be applied.
    mutating func load(from item: FileItem) {
        permissions = PropertyText.octal(item.permissions)
        prefilledPermissions = nil
        (date, time) = TimestampChange.fieldTexts(for: item.modified)
        (changesDate, usesCurrentTime) = (true, false)
    }

    /// Pre-fills the dialog from command parameters.
    mutating func take(_ change: AttributeChange) {
        recurse = change.recurse
        // Whatever the parameters ask for is shown, changes like `u+x` as they were written.
        if change.permissions != .unchanged {
            permissions = change.permissions.text
            prefilledPermissions = nil
        }
        if let hidden = change.hidden { self.hidden = hidden ? 1 : 2 }
        if let locked = change.locked { self.locked = locked ? 1 : 2 }
        if let timestamp = change.timestamp {
            func part(_ index: Int, _ letters: String, _ width: Int) -> String {
                timestamp.parts[index].map { String(format: "%0\(width)d", $0) } ?? letters
            }
            changesDate = true
            date = [part(0, "yyyy", 4), part(1, "mm", 2), part(2, "dd", 2)].joined(separator: "-")
            time = [part(3, "hh", 2), part(4, "mm", 2), part(5, "ss", 2)].joined(separator: ":")
        }
    }

    func fields(isLocal: Bool, details: LocalDetails?) -> [FormField] {
        func options(_ current: Bool?) -> [String] {
            guard let current else { return Self.flagOptions }
            return ["Unchanged (\(current ? "set" : "not set"))", "Set", "Clear"]
        }
        func now(_ name: String?) -> String { name.map { " (now \($0))" } ?? "" }
        var fields: [FormField] = [
            .checkbox("recurse", "Recurse into subdirectories", recurse),
            .text("permissions", "Permissions:", permissions),
            .note(
                "Octal (755), letters (rwxr-xr-x) or changes (u+x,go-w). Empty leaves them unchanged. "
                    + "Octal sets the mode as chmod does: 755 also clears set-user-ID, set-group-ID and sticky; 4755 sets them. "
                    + "Letters and changes keep those three."
            )
        ]
        if isLocal {
            fields += [
                .choice("hidden", "Hidden:", options(details?.isHidden), selected: hidden),
                .choice("locked", "Locked (read only):", options(details?.isLocked), selected: locked),
                .text("owner", "Owner\(now(details.map { LocalInfo.userName($0.ownerID) })):", owner),
                .text("group", "Group\(now(details.map { LocalInfo.groupName($0.groupID) })):", group)
            ]
        }
        fields += [
            .checkbox("changeDate", "Change date/time", changesDate),
            .text("date", "Date (yyyy-mm-dd):", date),
            .text("time", "Time (hh:mm:ss):", time),
            .checkbox("current", "Use the current date and time", usesCurrentTime),
            .note("A part written in letters keeps the file's own value: yyyy-05-dd changes only the month.")
        ]
        return fields
    }

    mutating func read(_ answer: FormValues) {
        recurse = answer.flag("recurse")
        permissions = answer.text("permissions")
        (hidden, locked) = (max(0, answer.index("hidden")), max(0, answer.index("locked")))
        (owner, group) = (answer.text("owner"), answer.text("group"))
        (changesDate, usesCurrentTime) = (answer.flag("changeDate"), answer.flag("current"))
        (date, time) = (answer.text("date"), answer.text("time"))
    }

    /// The change the dialog asks for, or what is wrong with an entry.
    func change(isLocal: Bool) -> Result<AttributeChange, Problem> {
        var change = AttributeChange()
        change.recurse = recurse
        let unchanged = permissions.trimmingCharacters(in: .whitespaces) == prefilledPermissions
        guard let permissions = PermissionChange(unchanged ? "" : permissions) else {
            return .failure(Problem(message: "The permissions \"\(permissions)\" cannot be read!"))
        }
        change.permissions = permissions
        if isLocal {
            change.hidden = hidden == 0 ? nil : hidden == 1
            change.locked = locked == 0 ? nil : locked == 1
            let (owner, group) = (
                owner.trimmingCharacters(in: .whitespaces), group.trimmingCharacters(in: .whitespaces)
            )
            change.owner = owner.isEmpty ? nil : owner
            change.group = group.isEmpty ? nil : group
        }
        if usesCurrentTime {
            change.timestamp = .current
        } else if changesDate {
            guard let timestamp = TimestampChange(date: date, time: time) else {
                return .failure(Problem(message: "The date \"\(date)\" or the time \"\(time)\" cannot be read!"))
            }
            change.timestamp = timestamp
        }
        return .success(change)
    }
}
