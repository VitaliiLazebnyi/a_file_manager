import AFMContracts
public import AFMKernel
public import AppKit

/// Files on the clipboard, shared with Finder, and the names of files as text
/// (spec 07 › File clipboard and name lists).
///
/// The system clipboard carries files of the local disks only, so cut and copy are offered there
/// and nowhere else. A text or a picture on the clipboard is pasted as a new file.
///
/// **Threading.** The panels are used on the main thread only, and so is the pasteboard for
/// everything else: `NSPasteboard` is not safe to use from another thread, so even the data of
/// a text or picture is read there. What writes a file or asks plugin columns for their values
/// runs inside a job, with everything it needs read beforehand. The name lists of very large
/// selections are put together on a background queue.
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
    /// Settings key: whether Paste makes a file of a text or picture on the clipboard.
    public static let pastesContentsKey = "clipboard.pasteContents"

    /// Selections up to this size go to the pasteboard as one object per file.
    internal static let eagerLimit = 1_000
    /// Name lists of more items than this are put together off the main thread.
    internal static let listedAtOnce = 2_000
    /// The list of paths as one property list, which the system derives from the files on
    /// the pasteboard: all of them in one read.
    internal static let fileNamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    /// Lists of more files than this from another program are read in slices.
    internal static let readAtOnce = 256
    /// The class the pasteboard reads file URLs as.
    private static var urlClasses: [AnyClass] { [URL._ObjectiveCType.self] }

    /// The plugin's name, for the log.
    public let name = "Clipboard"

    private let pasteboard: NSPasteboard
    /// The pasteboard state after the last Cut; while it is unchanged, Paste moves the files.
    private var cutChangeCount: Int?
    /// What this program put on the pasteboard last, while it is still there.
    private var placed: (changeCount: Int, urls: [URL])?
    /// The state of the pasteboard in which files were last found on it.
    private var filesFoundAt: Int?
    /// Hands the paths of a large selection to other programs, as text, when they ask.
    private var provider: FileListProvider?
    /// Puts the names and details on the clipboard, the latest request winning.
    internal let texts: TextClipboard
    /// The state of the pasteboard in which a text or picture was last found on it.
    private var contentFoundAt: Int?

    /// Tests pass a pasteboard of their own, so they leave the user's clipboard alone.
    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        texts = TextClipboard(pasteboard)
    }

    /// How many operands a snapshot stands for, without making the list of them.
    internal static func count(of operands: PanelModel.Operands) -> Int {
        operands.markedCount > 0 ? operands.markedCount : (operands.cursorItem == nil ? 0 : 1)
    }

    /// Registers Cut, Copy, Paste and the name lists, and adds them to the menus; main thread, once.
    public func start(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        let conditions = Conditions(kernel)
        registerFileCommands(in: kernel, conditions)
        registerNameCommands(in: kernel, conditions)
        registerDetailCommands(in: kernel, conditions)
        Self.addToMenus(kernel)
    }

    /// Cut, Copy and Paste.
    private func registerFileCommands(in owner: Kernel, _ conditions: Conditions) {
        unowned let kernel = owner
        let (model, isWritable, isRemoveOnly) = (conditions.model, conditions.isWritable, conditions.isRemoveOnly)
        kernel.commands.register(
            Command(.cutToClipboard, "Cut", [.cmd("x")]).editing(.cut),
            enabled: conditions.hasLocalOperands
        ) { [self] in
            place(model().operandsSnapshot(), cut: true, interaction: kernel.interaction)
        }
        kernel.commands.register(
            Command(.copyToClipboard, "Copy", [.cmd("c")]).editing(.copy),
            enabled: conditions.hasLocalOperands
        ) { [self] in
            place(model().operandsSnapshot(), cut: false, interaction: kernel.interaction)
        }
        kernel.commands.register(
            Command(.pasteFromClipboard, "Paste", [.cmd("v")]).editing(.paste),
            enabled: { [self] in (hasFiles() && !isRemoveOnly()) || (isWritable() && hasContent(in: kernel)) },
            { [self] in paste(in: kernel) }
        )
    }

    /// Puts the operands on the clipboard; the selection stays and nothing visible happens.
    ///
    /// Cut and Copy are offered only where there are operands.
    private func place(_ operands: PanelModel.Operands, cut: Bool, interaction: any UserInteraction) {
        let count = Self.count(of: operands)
        var forOthers = true
        if count > Self.eagerLimit {
            // Roughly what the system takes for that many; said so that the choice is an informed one.
            let seconds = max(1, count / 5_000)
            let answer = interaction.choose(
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
        texts.overtake()
        pasteboard.clearContents()
        if forOthers {
            provider = nil
            pasteboard.writeObjects(urls.map { $0 as any NSPasteboardWriting })
        } else {
            // One item for all of them: their paths as text, made when somebody asks for it.
            let listProvider = FileListProvider(urls)
            let item = NSPasteboardItem()
            item.setDataProvider(listProvider, forTypes: [.string])
            pasteboard.writeObjects([item])
            provider = listProvider
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
        let found = pasteboard.canReadObject(forClasses: Self.urlClasses, options: [.urlReadingFileURLsOnly: true])
        filesFoundAt = found ? count : nil
        return found
    }

    /// The files another program put on the clipboard (what this program put there itself is
    /// not read back through the pasteboard); empty, like none, when they cannot be read.
    private func files() -> [URL] {
        // The whole list in one piece, where the other program offers it: one read instead of one per file.
        if let paths = pasteboard.propertyList(forType: Self.fileNamesType) as? [String], !paths.isEmpty {
            return paths.map { path in URL(fileURLWithPath: path, isDirectory: false) }
        }
        let read = pasteboard.readObjects(forClasses: Self.urlClasses, options: [.urlReadingFileURLsOnly: true])
        // A read that fails gives none, like a list without files.
        return Array([read].compactMap { objects in objects as? [URL] }.joined())
    }

    /// Pastes into the source panel's folder at once, without a dialog.
    ///
    /// Files are transferred by whichever plugin offers the file-transfer service; a text or
    /// picture becomes a file.
    private func paste(in kernel: Kernel) {
        let directory = kernel.panels.source.model.directory
        let isMove = cutChangeCount == pasteboard.changeCount
        readFiles(in: kernel) { [self] files in
            guard !files.isEmpty else {
                // Read here, on the main thread (see Threading above); the job gets the data only.
                if hasContent(in: kernel), let content = PastedContent.read(from: pasteboard) {
                    content.paste(into: directory, in: kernel)
                }
                return
            }
            guard let transfers = kernel.services.find((any FileTransferService).self) else {
                return kernel.commands.onRejected()
            }
            // A copy pasted next to its original gets a new name: "report (2).txt". Files that are
            // moved into the folder they are in already are left out by the service, on its own
            // thread: telling that needs the real folder behind a branch view.
            transfers.transfer(
                isMove ? .move : .copy,
                files,
                into: directory,
                renamingSelfCopies: !isMove
            ) { [self] arrived in
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
    private func readFiles(in kernel: Kernel, then deliver: @escaping ([URL]) -> Void) {
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
        let found = pasteboard.availableType(from: PastedContent.imageTypes + [.string]) != nil
        contentFoundAt = found ? count : nil
        return found
    }

    deinit {
        // Nothing to release.
    }
}
