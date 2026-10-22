import AFMContracts
public import AFMKernel
public import AppKit

/// The commands only this plugin provides (spec 17 › Clipboard).
///
/// The `Net` variants write URLs, which is what a UNC path is on the Mac.
public enum ClipboardCommands {
    public static let copyNames: CommandID = "cm_CopyNamesToClip"
    public static let copyNetNames: CommandID = "cm_CopyNetNamesToClip"
    public static let copyPathOfFiles: CommandID = "cm_CopyPathOfFilesToClip"
    public static let copySourcePath: CommandID = "cm_CopySrcPathToClip"
    public static let copyTargetPath: CommandID = "cm_CopyTrgPathToClip"
    /// `.index`: a bit mask of the columns to copy (1 = name, 2 = size, 4 = date, …); without, all.
    public static let copyDetails: CommandID = "cm_CopyFileDetailsToClip"
    public static let copyDetailsWithPath: CommandID = "cm_CopyFpFileDetailsToClip"
    public static let copyDetailsWithURL: CommandID = "cm_CopyNetFileDetailsToClip"
    public static let copyDetailsWithHeaders: CommandID = "cm_CopyHdrFileDetailsToClip"
    public static let copyDetailsWithHeadersAndPath: CommandID = "cm_CopyHdrFpFileDetailsToClip"
    public static let copyDetailsWithHeadersAndURL: CommandID = "cm_CopyHdrNetFileDetailsToClip"
    /// `.text`: the file to write, as the user would type it; without, the name is asked for.
    public static let saveDetails: CommandID = "cm_SaveDetailsToFile"
    public static let saveDetailsWithHeaders: CommandID = "cm_SaveHdrDetailsToFile"
}

/// Files on the clipboard, shared with Finder, and the names of files as text
/// (spec 07 › File clipboard and name lists).
///
/// The system clipboard carries files of the local disks only, so cut and copy are offered there
/// and nowhere else. A text or a picture on the clipboard is pasted as a new file.
///
/// **Threading.** The panels are used on the main thread only, and so is the pasteboard for
/// everything else: `NSPasteboard` is not safe to use from another thread, so even the data of
/// a text or picture is read there. What writes a file or asks plugin columns for their values
/// runs inside a job, with everything it needs read beforehand. The name lists of very large selections are put together on a background queue.
///
/// **Large selections.** Putting files on the pasteboard costs the system a tenth of a
/// millisecond or more per file, on the main thread, and there is no way around it: a file is
/// one pasteboard item, the items become visible to other programs one by one as they are
/// written (so writing them in the background would show half a selection), and the one type
/// that holds a whole list is neither offered lazily nor read as files by today's programs.
/// So up to `eagerLimit` files are written the usual way. Beyond that the user is asked: the
/// selection is always remembered here, which is all a Paste inside this program needs and
/// costs nothing; only if other programs are to get the files too are they written, and the
/// user has been told that this takes a while. Without that, other programs are offered the
/// paths as a text, made when one of them asks. This program never reads its own files back.
///
/// **Long lists from other programs.** Reading the files another program put there costs the
/// system some sixty millionths of a second per file, whichever way they are asked for
/// (measured: 2.2 s for 50,000 as one list, 2.7 s as objects), and the pasteboard may only be
/// read on the main thread. A long list is therefore read a few milliseconds' worth at a time,
/// with the main thread free in between and a job that shows how far it is and can be
/// cancelled (`FileListReading`).
public final class ClipboardPlugin: Plugin {
    public let name = "Clipboard"
    /// Settings key: whether Paste makes a file of a text or picture on the clipboard.
    public static let pastesContentsKey = "clipboard.pasteContents"

    /// Selections up to this size go to the pasteboard as one object per file.
    internal static let eagerLimit = 1_000
    /// Name lists of more items than this are put together off the main thread.
    internal static let listedAtOnce = 2_000
    /// The list of paths as one property list, which the system derives from the files on
    /// the pasteboard: all of them in one read.
    internal static let fileNamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    private let pasteboard: NSPasteboard
    /// The pasteboard state after the last Cut; while it is unchanged, Paste moves the files.
    private var cutChangeCount: Int?
    /// What this program put on the pasteboard last, while it is still there.
    private var placed: (changeCount: Int, urls: [URL])?
    /// The state of the pasteboard in which files were last found on it.
    private var filesFoundAt: Int?
    /// Hands the paths of a large selection to other programs, as text, when they ask.
    private var provider: FileListProvider?
    /// Counts the name lists asked for, so that a slow one does not overwrite a later one.
    private var listRequest = 0
    /// Lists of more files than this from another program are read in slices.
    internal static let readAtOnce = 256
    /// The state of the pasteboard in which a text or picture was last found on it.
    private var contentFoundAt: Int?

    /// Tests pass a pasteboard of their own, so they leave the user's clipboard alone.
    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public func start(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        let commands = kernel.commands
        let model = { kernel.panels.source.model }
        let hasOperands = { model().hasOperands }
        let hasLocalOperands = { model().hasOperands && model().directory.isFileURL }
        /// Whether something new can be put into the folder the panel shows: where entries
        /// can only be removed (a list of files from anywhere, `.removeOnly`) nothing can.
        let capabilities = { kernel.fileSystems.capabilities(for: model().directory) }
        let isWritable = { capabilities().contains(.write) && !capabilities().contains(.removeOnly) }
        let isRemoveOnly = { capabilities().contains(.removeOnly) }
        let fileSystems = kernel.fileSystems
        let displayPath: @Sendable (URL) -> String = { fileSystems.displayPath($0) }
        let list = NameList(displayPath: displayPath)

        commands.register(Command(.cutToClipboard, "Cut", [.cmd("x")]).editing(.cut), enabled: hasLocalOperands) {
            [self] in
            place(model().operandsSnapshot(), cut: true, ui: kernel.interaction)
        }
        commands.register(
            Command(.copyToClipboard, "Copy", [.cmd("c")]).editing(.copy),
            enabled: hasLocalOperands
        ) { [self] in
            place(model().operandsSnapshot(), cut: false, ui: kernel.interaction)
        }
        commands.register(
            Command(.pasteFromClipboard, "Paste", [.cmd("v")]).editing(.paste),
            enabled: { [self] in (hasFiles() && !isRemoveOnly()) || (isWritable() && hasContent(in: kernel)) }
        ) { [self] in paste(in: kernel) }

        // Names as text. They change nothing, so they also work while a job runs.
        /// `text` makes the text from the operands; it may run off the main thread.
        func names(
            _ id: CommandID,
            _ title: String,
            _ shortcuts: [Shortcut] = [],
            enabled: @escaping () -> Bool = { true },
            _ text: @escaping @Sendable ([FileItem], URL) -> String
        ) {
            commands.register(Command(id, title, shortcuts, runsDuringJobs: true), enabled: enabled) { [self] in
                // The list of the operands is made where the text is: for a long selection
                // that is not the main thread.
                let (operands, directory) = (model().operandsSnapshot(), model().directory)
                putText(for: Self.count(of: operands)) { text(operands.items(), directory) }
            }
        }
        names(ClipboardCommands.copyNames, "Copy Names", enabled: hasOperands) { items, _ in list.names(items, .name) }
        names(.copyFullNames, "Copy Names with Path", [.cmd("c", .shift)]) { items, directory in
            // On `[..]` with nothing selected there is no item: the folder itself is meant.
            items.isEmpty ? displayPath(directory) : list.names(items, .fullPath)
        }
        names(ClipboardCommands.copyNetNames, "Copy Names as URLs", enabled: hasOperands) { items, _ in
            list.names(items, .url)
        }
        names(ClipboardCommands.copyPathOfFiles, "Copy Path of Each File", enabled: hasOperands) { items, _ in
            list.parentPaths(items)
        }
        commands.register(Command(ClipboardCommands.copySourcePath, "Copy Source Path", runsDuringJobs: true)) {
            [self] in
            put(displayPath(model().directory))
        }
        commands.register(Command(ClipboardCommands.copyTargetPath, "Copy Target Path", runsDuringJobs: true)) {
            [self] in
            put(displayPath(kernel.panels.target.model.directory))
        }

        let detailCommands: [(CommandID, String, NameList.Style, Bool)] = [
            (ClipboardCommands.copyDetails, "Copy with All Details", .name, false),
            (ClipboardCommands.copyDetailsWithPath, "Copy with Path and Details", .fullPath, false),
            (ClipboardCommands.copyDetailsWithURL, "Copy with URL and Details", .url, false),
            (ClipboardCommands.copyDetailsWithHeaders, "Copy with Details and Headers", .name, true),
            (ClipboardCommands.copyDetailsWithHeadersAndPath, "Copy with Path, Details and Headers", .fullPath, true),
            (ClipboardCommands.copyDetailsWithHeadersAndURL, "Copy with URL, Details and Headers", .url, true)
        ]
        for (id, title, style, headers) in detailCommands {
            commands.register(
                Command(id, title),
                enabled: hasOperands,
                parameterized: { [self] argument in
                    details(style, headers: headers, mask: argument.index, in: kernel) { [self] text in put(text) }
                }
            )
        }
        for (id, title, headers) in [
            (ClipboardCommands.saveDetails, "Save Details to File…", false),
            (ClipboardCommands.saveDetailsWithHeaders, "Save Details with Headers to File…", true)
        ] {
            commands.register(
                Command(id, title),
                enabled: { hasOperands() && isWritable() },
                parameterized: { [self] argument in
                    saveDetails(headers: headers, to: argument.text, in: kernel)
                }
            )
        }

        kernel.menus.add([.cutToClipboard, .copyToClipboard, .pasteFromClipboard], to: .editClipboard)
        kernel.menus.add(
            [
                ClipboardCommands.copyNames, .copyFullNames, ClipboardCommands.copyNetNames,
                ClipboardCommands.copyDetails,
                ClipboardCommands.copyDetailsWithPath, ClipboardCommands.copyDetailsWithHeaders
            ],
            to: .editNames
        )
        kernel.menus.add(
            [ClipboardCommands.copySourcePath, ClipboardCommands.copyTargetPath, ClipboardCommands.saveDetails],
            to: MenuSection(.edit, order: 30)
        )
        kernel.menus.addToContextMenu([.cutToClipboard, .copyToClipboard], in: .clipboard, onItemOnly: true)
        kernel.menus.addToContextMenu([.pasteFromClipboard], in: .clipboard)
        kernel.menus.addToContextMenu([.copyFullNames], in: .tools)
        kernel.menus.addToContextMenu([ClipboardCommands.copyNames], in: .tools, onItemOnly: true)

        kernel.toolbar.setSymbol("scissors", for: .cutToClipboard)
        kernel.toolbar.setSymbol("doc.on.doc", for: .copyToClipboard)
        kernel.toolbar.setSymbol("doc.on.clipboard", for: .pasteFromClipboard)
        kernel.toolbar.setSymbol("list.clipboard", for: .copyFullNames)
        kernel.preferences.add(
            PreferencePage(
                title: "Clipboard",
                preferences: [
                    Preference(
                        Self.pastesContentsKey,
                        "Paste a text or picture from the clipboard as a new file",
                        .flag(default: true)
                    )
                ]
            )
        )
    }

    // MARK: Files

    /// How many operands a snapshot stands for, without making the list of them.
    internal static func count(of operands: PanelModel.Operands) -> Int {
        operands.markedCount > 0 ? operands.markedCount : (operands.cursorItem == nil ? 0 : 1)
    }

    /// Puts the operands on the clipboard; the selection stays and nothing visible happens.
    ///
    /// Cut and Copy are offered only where there are operands.
    private func place(_ operands: PanelModel.Operands, cut: Bool, ui: any UserInteraction) {
        let count = Self.count(of: operands)
        var forOthers = true
        if count > Self.eagerLimit {
            // Roughly what the system takes for that many; said so that the choice is an informed one.
            let seconds = max(1, count / 5_000)
            let answer = ui.choose(
                "\(cut ? "Cut" : "Copy") \(count) files",
                detail: "They can be pasted in this program at once. Offering them to other programs as well (Finder) "
                    + "takes about \(seconds) second(s), during which this program does not respond.",
                buttons: ["For This Program", "Also for Other Programs", "Cancel"],
                style: .information
            )
            guard answer == 0 || answer == 1 else {
                return
            }
            forOthers = answer == 1
        }
        let urls = operands.items().map(\.url)
        // A list of names that is still being put together must not land on top of the files.
        listRequest += 1
        pasteboard.clearContents()
        if forOthers {
            provider = nil
            pasteboard.writeObjects(urls.map { $0 as NSURL })
        } else {
            // One item for all of them: their paths as text, made when somebody asks for it.
            let provider = FileListProvider(urls)
            let item = NSPasteboardItem()
            item.setDataProvider(provider, forTypes: [.string])
            pasteboard.writeObjects([item])
            self.provider = provider
        }
        placed = (pasteboard.changeCount, urls)
        cutChangeCount = cut ? pasteboard.changeCount : nil
    }

    /// Whether files are on the clipboard.
    ///
    /// The menus ask this at every validation, and with many files on the pasteboard the question
    /// is not cheap: a yes is remembered for as long as the pasteboard stays in the state it was
    /// found in. A no is asked again each time: it is cheap, and it cannot be remembered, because
    /// files written after the pasteboard was cleared arrive in the same state of it (the count
    /// moves when it is cleared, not when something is added).
    private func hasFiles() -> Bool {
        let count = pasteboard.changeCount
        if let placed {
            if placed.changeCount == count {
                return true
            }
            // Somebody else wrote to the pasteboard: the remembered selection is let go.
            (self.placed, provider) = (nil, nil)
        }
        if filesFoundAt == count {
            return true
        }
        let found = pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        filesFoundAt = found ? count : nil
        return found
    }

    /// The files another program put on the clipboard (what this program put there itself is
    /// not read back through the pasteboard); nil, like none, when they cannot be read.
    private func files() -> [URL]? {
        // The whole list in one piece, where the other program offers it: one read instead of one per file.
        if let paths = pasteboard.propertyList(forType: Self.fileNamesType) as? [String], !paths.isEmpty {
            return paths.map { URL(fileURLWithPath: $0, isDirectory: false) }
        }
        return pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }

    /// Pastes into the source panel's folder at once, without a dialog.
    ///
    /// Files are transferred by whichever plugin offers the file-transfer service; a text or
    /// picture becomes a file.
    private func paste(in kernel: Kernel) {
        let directory = kernel.panels.source.model.directory
        let isMove = cutChangeCount == pasteboard.changeCount
        readFiles(in: kernel) { [self] files in
            guard let files, !files.isEmpty else {
                if hasContent(in: kernel) { pasteContent(into: directory, in: kernel) }
                return
            }
            guard let transfers = kernel.services.find((any FileTransferService).self) else {
                return kernel.commands.onRejected()
            }
            // A copy pasted next to its original gets a new name: "report (2).txt". Files that are
            // moved into the folder they are in already are left out by the service, on its own
            // thread: telling that needs the real folder behind a branch view.
            transfers.transfer(isMove ? .move : .copy, files, into: directory, renamingSelfCopies: !isMove) {
                [self] arrived in
                // Files that were cut stay cut until some of them have really been moved: a Paste
                // into the folder they are in moves nothing, and the next Paste elsewhere still moves.
                if isMove, arrived != nil { cutChangeCount = nil }
            }
        }
    }

    /// The files on the clipboard, handed over on the main thread.
    ///
    /// What this program put there, and a short list, at once; a long list from another program
    /// after it was read slice by slice, with a job that shows the reading and lets it be
    /// cancelled. Nothing is handed over when the reading was cancelled or the clipboard changed
    /// meanwhile.
    private func readFiles(in kernel: Kernel, then deliver: @escaping ([URL]?) -> Void) {
        if let placed, placed.changeCount == pasteboard.changeCount {
            deliver(placed.urls)
            return
        }
        guard let items = pasteboard.pasteboardItems, items.count > Self.readAtOnce else {
            deliver(files())
            return
        }
        // Paste is not offered while the reading's job runs: there is never a second reading.
        let reading = FileListReading(items, on: pasteboard)
        let title = "Reading the clipboard:"
        kernel.jobs.run(
            title: title,
            work: { monitor in
                reading.run(cancellation: monitor.cancellation) { done, total in
                    monitor.report(
                        JobProgress(lines: [title, "\(done) of \(total) files"], itemsDone: done, itemsTotal: total)
                    )
                }
            },
            completion: { [self] (outcome: FileListReading.Outcome) in
                switch outcome {
                case .abandoned:
                    break

                // Items that are not file locations one by one (an old program's list): asked for whole.
                case .read(let urls):
                    deliver(urls.isEmpty ? files() : urls)
                }
            }
        )
    }

    // MARK: Text and pictures

    private static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]

    /// Whether a picture or text is there to paste; looks at the kinds only, so menus can ask often.
    ///
    /// A yes is remembered for the state of the pasteboard it was found in, so that a menu that
    /// asks at every validation costs one question; a no is asked again, as for files.
    private func hasContent(in kernel: Kernel) -> Bool {
        guard kernel.settings.flag(Self.pastesContentsKey, default: true) else {
            return false
        }
        let count = pasteboard.changeCount
        if contentFoundAt == count {
            return true
        }
        let found = pasteboard.availableType(from: Self.imageTypes + [.string]) != nil
        contentFoundAt = found ? count : nil
        return found
    }

    /// The picture or text on the clipboard.
    ///
    /// A picture wins over a text, because programs that copy a picture often add its name. Reads
    /// the data, which the program that owns it may make only now. Main thread.
    private static func content(of pasteboard: NSPasteboard) -> PastedContent? {
        if let type = pasteboard.availableType(from: imageTypes), let data = pasteboard.data(forType: type),
            !data.isEmpty
        {
            return .image(data)
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return .text(text)
        }
        return nil
    }

    private struct NothingToPaste: Error {}

    /// Writes the content as `Clipboard.txt` or `Clipboard.png` (with a number when the name
    /// is taken) through the folder's file system, in a job; the cursor goes to the new file.
    ///
    /// The file is written under a temporary name and gets its own when it is complete, so a write
    /// that fails leaves no half of it behind.
    private func pasteContent(into directory: URL, in kernel: Kernel) {
        let fileSystems = kernel.fileSystems
        // Read here, on the main thread (see Threading above); the job gets the data only.
        guard let content = Self.content(of: pasteboard) else {
            return
        }
        kernel.jobs.run(
            title: "Paste:",
            work: { monitor -> Result<URL, any Error> in
                let cancellation = monitor.cancellation
                return Result {
                    let provider = try fileSystems.provider(for: directory)
                    let data: Data
                    switch content {
                    case .text(let text):
                        data = Data(text.utf8)

                    case .image(let picture):
                        data = try Self.png(from: picture)
                    }
                    let name = PastedContent.freeName(extension: content.fileExtension) {
                        provider.item(at: directory.appending(name: $0), cancellation: cancellation) != nil
                    }
                    if cancellation.isCancelled { throw NothingToPaste() }
                    let url = directory.appending(name: name)
                    let draft = directory.appending(name: ".\(name).\(UUID().uuidString.prefix(8)).tmp")
                    do {
                        let writer = try provider.write(draft, cancellation: cancellation)
                        do {
                            try writer.write(data)
                            try writer.close(attributes: FileAttributes())
                        } catch {
                            try? writer.close(attributes: FileAttributes())
                            throw error
                        }
                        try provider.move(draft, to: url, replacing: false, cancellation: cancellation)
                    } catch {
                        // Tidying up: not with the job's flag, which may be what ended the writing.
                        try? provider.remove(draft)
                        throw cancellation.isCancelled ? NothingToPaste() : error
                    }
                    return url
                }
            },
            completion: { result in
                switch result {
                case .success(let url):
                    kernel.panels.refresh([directory], focus: url)

                case .failure(is NothingToPaste):
                    break

                case .failure(let error):
                    kernel.interaction.report(error, title: "The clipboard cannot be pasted as a file!")
                }
            }
        )
    }

    private struct NotAPicture: LocalizedError {
        var errorDescription: String? { "The picture on the clipboard cannot be read." }
    }

    /// PNG data stays as it is; anything else is converted.
    ///
    /// Runs on a job's thread.
    nonisolated private static func png(from data: Data) throws -> Data {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return data
        }
        guard let converted = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else {
            throw NotAPicture()
        }
        return converted
    }

    // MARK: Names and details

    /// Puts a text on the clipboard.
    ///
    /// Whatever list of names is still being put together for an earlier command is overtaken by
    /// this: it must not replace the text later.
    private func put(_ text: String) {
        listRequest += 1
        write(text)
    }

    private func write(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Puts the text `make` returns on the clipboard.
    ///
    /// For a few items at once; for a very large selection the text is put together on a background
    /// queue (it is megabytes of paths) and only handed to the pasteboard here. The latest request
    /// wins: a text that arrives after something newer went to the clipboard (another text, or
    /// files) is dropped.
    private func putText(for count: Int, _ make: @escaping @Sendable () -> String) {
        guard count > Self.listedAtOnce else {
            put(make())
            return
        }
        listRequest += 1
        let request = listRequest
        // On a thread of the kernel's own: the shared queues may be busy with work that waits.
        BlockingCalls.run {
            let text = make()
            DispatchQueue.main.async { [self] in
                if request == listRequest { write(text) }
            }
        }
    }

    /// Works out the details lines of the operands in a job, because the plugin columns the
    /// panel shows may block on the file system, and hands the text over on the main thread.
    private func details(
        _ style: NameList.Style,
        headers: Bool,
        mask: Int?,
        in kernel: Kernel,
        then completion: @escaping @MainActor (String) -> Void
    ) {
        let (operands, extra) = detailsInput(in: kernel)
        let list = Self.nameList(in: kernel)
        kernel.jobs.run(
            title: "Reading details:",
            work: { _ in
                list.details(operands.items(), style, headers: headers, extra: extra, mask: mask)
            },
            completion: completion
        )
    }

    /// A name list that writes locations as the kernel's file systems do.
    private static func nameList(in kernel: Kernel) -> NameList {
        let fileSystems = kernel.fileSystems
        return NameList(displayPath: { fileSystems.displayPath($0) })
    }

    /// The operands and the plugin columns the source panel shows, read on the main thread.
    private func detailsInput(in kernel: Kernel) -> (operands: PanelModel.Operands, extra: [NameList.Column]) {
        let panel = kernel.panels.source
        let shown = panel.viewMode == .full ? panel.extraColumns.compactMap { kernel.columns[$0] } : []
        return (panel.model.operandsSnapshot(), shown.map { NameList.Column(title: $0.title, value: $0.value) })
    }

    /// Writes the details lines to a file through its file system (spec 03 › Selection files,
    /// `cm_SaveDetailsToFile`).
    ///
    /// An existing file is replaced only after a question.
    private func saveDetails(headers: Bool, to proposed: String?, in kernel: Kernel) {
        let directory = kernel.panels.source.model.directory
        guard let text = proposed ?? kernel.interaction.prompt("Save details to file:", value: "details.txt"),
            !text.trimmingCharacters(in: .whitespaces).isEmpty
        else { return }
        let (operands, extra) = detailsInput(in: kernel)
        let (fileSystems, ui) = (kernel.fileSystems, kernel.interaction)
        let list = Self.nameList(in: kernel)
        let url = fileSystems.location(from: text, relativeTo: directory)
        kernel.jobs.run(
            title: "Saving details:",
            work: { monitor -> any Error? in
                do {
                    let provider = try fileSystems.provider(for: url)
                    let cancellation = monitor.cancellation
                    let existing = provider.item(at: url, cancellation: cancellation)
                    if cancellation.isCancelled {
                        return CocoaError(.userCancelled)
                    }
                    if let existing {
                        // Only a file is replaced; a folder of that name is not this command's to remove.
                        if existing.isDirectory { throw FileSystemError.alreadyExists(fileSystems.displayPath(url)) }
                        // Return keeps the file that is there.
                        // `@Sendable`, so that it may be sent from this thread to the main thread.
                        let replace = monitor.ask { @Sendable in
                            ui.choose(
                                "Overwrite:",
                                detail: Format.displayName(fileSystems.displayPath(url)),
                                buttons: ["Overwrite", "Cancel"],
                                style: .warning,
                                defaultButton: 1
                            ) == 0
                        }
                        guard replace else {
                            return CocoaError(.userCancelled)
                        }
                    }
                    // Written next to the target and moved into place when complete: a failed write
                    // leaves the old file as it was, and nothing is removed before there is a new one.
                    let draft = url.deletingLastPathComponent()
                        .appending(
                            name: ".\(url.lastPathComponent).\(UUID().uuidString.prefix(8)).tmp"
                        )
                    do {
                        let writer = try provider.write(draft, cancellation: cancellation)
                        do {
                            try writer.write(
                                Data(list.details(operands.items(), .name, headers: headers, extra: extra).utf8)
                            )
                            try writer.close(attributes: FileAttributes())
                        } catch {
                            try? writer.close(attributes: FileAttributes())
                            throw error
                        }
                        try provider.move(draft, to: url, replacing: existing != nil, cancellation: cancellation)
                    } catch {
                        try? provider.remove(draft)
                        throw cancellation.isCancelled ? CocoaError(.userCancelled) : error
                    }
                    return nil
                } catch {
                    return error
                }
            },
            completion: { error in
                // Declining to overwrite is no failure and changes nothing.
                if (error as? CocoaError)?.code == .userCancelled {
                    return
                }
                if let error { kernel.interaction.report(error, title: "The details cannot be saved!") }
                kernel.panels.refresh([url.deletingLastPathComponent()], focus: error == nil ? url : nil)
            }
        )
    }
}

/// The paths of a large selection as text, for other programs: nothing is made until one of
/// them asks, and then the whole list in one piece.
///
/// **Threading.** The pasteboard calls on the main thread; the list never changes.
internal final class FileListProvider: NSObject, NSPasteboardItemDataProvider {
    private let urls: [URL]

    internal init(_ urls: [URL]) {
        self.urls = urls
    }

    internal func pasteboard(
        _: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        item.setString(urls.map(\.path).joined(separator: "\n"), forType: type)
    }
}

/// Reads a long list of files that another program put on the pasteboard without holding up
/// the main thread: the pasteboard may only be read there, and every file is a question to
/// the system (see `ClipboardPlugin`).
///
/// The items are asked a few milliseconds' worth per turn of the main run loop.
///
/// **Threading.** `run` is called on a job's thread and waits there; the reading happens on
/// the main thread in slices it schedules. Called on the main thread itself (a job service
/// that runs its work at once) it reads everything in one go, as there is nobody to wait for.
/// The counters the two threads share are behind `lock`.
///
/// Unchecked: the counters are guarded by `lock`; the items and the pasteboard are only
/// touched on the main thread.
internal final class FileListReading: @unchecked Sendable {
    internal enum Outcome: Equatable {
        case read([URL])
        /// Cancelled, or the pasteboard got other contents while it was read.
        case abandoned
    }

    /// How long one slice may take before the main thread gets its turn again.
    internal static let sliceTime: UInt64 = 6_000_000

    private let items: [NSPasteboardItem]
    private let pasteboard: NSPasteboard
    private let changeCount: Int
    private let lock = NSLock()
    private var next = 0
    private var urls: [URL] = []
    /// What the reading came to; set before `finished` is signalled.
    private var outcome = Outcome.abandoned
    private let finished = DispatchSemaphore(value: 0)
    private var sliceCount = 0
    /// How many slices the reading took; for tests.
    internal var slices: Int { lock.withLock { sliceCount } }

    /// Main thread: the pasteboard's state is noted here.
    internal init(_ items: [NSPasteboardItem], on pasteboard: NSPasteboard) {
        self.items = items
        self.pasteboard = pasteboard
        changeCount = pasteboard.changeCount
    }

    /// Blocks until the list is read. `progress` (done, total) is called on the calling
    /// thread about ten times a second while it waits.
    internal func run(cancellation: CancellationFlag, progress: (Int, Int) -> Void) -> Outcome {
        if Thread.isMainThread {
            step(cancellation, sliced: false)
        } else {
            DispatchQueue.main.async { self.step(cancellation, sliced: true) }
            while finished.wait(timeout: .now() + 0.1) == .timedOut {
                progress(lock.withLock { next }, items.count)
            }
        }
        return lock.withLock { outcome }
    }

    /// One slice.
    ///
    /// Main thread.
    private func step(_ cancellation: CancellationFlag, sliced: Bool) {
        guard !cancellation.isCancelled, pasteboard.changeCount == changeCount else {
            finish(.abandoned)
            return
        }
        let start = DispatchTime.now().uptimeNanoseconds
        var (index, found): (Int, [URL]) = (lock.withLock { next }, [])
        repeat {
            guard index < items.count else { break }
            if let url = Self.fileURL(of: items[index]) { found.append(url) }
            index += 1
        } while !sliced || DispatchTime.now().uptimeNanoseconds - start < Self.sliceTime
        let isDone = index >= items.count
        lock.withLock {
            next = index
            urls += found
            sliceCount += 1
        }
        // Both ways are rare against the loop above, so each is a case of its own.
        switch isDone {
        case false:
            DispatchQueue.main.async { self.step(cancellation, sliced: sliced) }

        case true:
            // Changed while the last slice was read: what was read may be half of each.
            finish(pasteboard.changeCount == changeCount ? .read(lock.withLock { urls }) : .abandoned)
        }
    }

    private func finish(_ result: Outcome) {
        lock.withLock { outcome = result }
        finished.signal()
    }

    /// The file an item stands for, if it is one.
    internal static func fileURL(of item: NSPasteboardItem) -> URL? {
        guard let text = item.string(forType: .fileURL), let url = URL(string: text), url.isFileURL else {
            return nil
        }
        // A reference to a file by its number instead of its path is turned into the path (newer
        // systems give the path when it is asked for, older ones the number).
        if text.hasPrefix("file:///.file/") {
            return (url as NSURL).filePathURL
        }
        return url
    }
}
