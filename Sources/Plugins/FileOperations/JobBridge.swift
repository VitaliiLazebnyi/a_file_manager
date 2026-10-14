import AFMContracts
import AFMKernel
import Foundation

/// Connects a running job to its progress window and turns its questions into dialogs.
///
/// **Threading.** The job calls from its own threads; every dialog is shown through
/// `JobMonitor.ask`, which takes it to the main thread and waits. What needs to read files
/// (comparing two files) runs on the calling job thread, between two dialogs.
final class JobBridge: FileJobDelegate {
    private let monitor: JobMonitor
    private let ui: UserInteraction
    private let fileSystems: FileSystemRegistry

    init(monitor: JobMonitor, ui: UserInteraction, fileSystems: FileSystemRegistry) {
        self.monitor = monitor
        self.ui = ui
        self.fileSystems = fileSystems
    }

    func job(_: FileJob, progress: JobProgress) {
        monitor.report(progress)
    }

    /// What the Overwrite dialog came back with: an answer for the job, or a wish to compare first.
    private enum OverwriteStep {
        case answer(ConflictChoice)
        case compare
    }

    /// The entries behind "More…", in the order of the spec's menu, with Append and Resume
    /// where they make sense.
    private enum MoreOption: String {
        case compare = "Compare contents"
        case append = "Append to the target file"
        case resume = "Resume: the target is the beginning of the file, add the rest"
        case renameExisting = "Rename existing target file…"
        case autoRenameCopied = "Auto-rename copied"
        case autoRenameExisting = "Auto-rename target files"
        case renameOlderSkipNewer = "Rename older target files, skip newer"
        case olderOrSame = "Overwrite all older and of the same age"
        case larger = "Copy all larger files (overwrite smaller)"
        case smaller = "Copy all smaller files (overwrite larger)"
    }

    /// The Overwrite dialog (spec 07 › Name collisions). The six everyday answers and Rename
    /// are buttons; the rest is behind "More…".
    func job(_ job: FileJob, conflictAt target: FileItem, source: FileItem) -> ConflictChoice {
        func describe(_ item: FileItem) -> String {
            "\(shown(item.url))\n\(Format.bytes(item.size)) bytes, \(Format.date(item.modified))"
        }
        let detail =
            "\(describe(target))\n\nWith file:\n\(describe(source))\n\n\(OperationText.comparison(source: source, target: target))"
        var more: [MoreOption] = [.compare]
        // Append is not offered when the collision comes from a move (07 › Name conflicts during rename or move).
        // Only a plain file is continued: a link at the target would lead the writing elsewhere.
        let isPlain = !target.isSymlink && !target.isSpecial && !source.isSpecial
        if job.kind == .copy, isPlain { more.append(.append) }
        if target.size < source.size, isPlain { more.append(.resume) }
        more += [
            .renameExisting, .autoRenameCopied, .autoRenameExisting, .renameOlderSkipNewer, .olderOrSame, .larger,
            .smaller
        ]
        while true {
            let step: OverwriteStep = monitor.ask {
                while true {
                    // Return presses Skip: a file that is overwritten is gone, one that is skipped
                    // can still be copied.
                    let button = ui.choose(
                        "Overwrite:", detail: detail,
                        buttons: [
                            "Overwrite", "Overwrite all", "Skip", "Skip all", "Overwrite all older",
                            "Rename…", "More…", "Cancel"
                        ], style: .warning,
                        defaultButton: Self.overwriteDefault)
                    switch button {
                    case 0: return .answer(.overwrite)
                    case 1: return .answer(.overwriteAll)
                    case 2: return .answer(.skip)
                    case 3: return .answer(.skipAll)
                    case 4: return .answer(.overwriteAllOlder)

                    case 5:
                        if let name = newName("New name for the file being copied:", proposing: target.name) {
                            return .answer(.rename(name))
                        }

                    case 6:
                        guard
                            let row = ui.pickRow(
                                "Overwrite: more options", detail: shown(target.url), rows: more.map(\.rawValue))
                        else { continue }
                        switch more[row] {
                        case .compare: return .compare
                        case .append: return .answer(.append)
                        case .resume: return .answer(.resume)

                        case .renameExisting:
                            if let name = newName("New name for the existing target file:", proposing: target.name) {
                                return .answer(.renameExisting(name))
                            }

                        case .autoRenameCopied: return .answer(.autoRenameCopied)
                        case .autoRenameExisting: return .answer(.autoRenameExisting)
                        case .renameOlderSkipNewer: return .answer(.renameOlderSkipNewer)
                        case .olderOrSame: return .answer(.overwriteAllOlderOrSame)
                        case .larger: return .answer(.copyAllLarger)
                        case .smaller: return .answer(.copyAllSmaller)
                        }

                    default: return .answer(.cancel)
                    }
                }
            }
            guard case .compare = step else {
                if case .answer(let choice) = step { return choice }
                return .cancel
            }
            // Compare takes no decision: the files are read here, off the main thread, and the
            // Overwrite dialog comes back.
            let same = try? Checksum.sameContents(
                source.url, target.url, in: fileSystems, flags: [monitor.cancellation]
            ) { self.monitor.cancellation.isCancelled }
            if monitor.cancellation.isCancelled { return .cancel }
            monitor.ask {
                let paths = "\(shown(source.url))\n\(shown(target.url))"
                switch same {
                case true?: ui.inform("The two files have the same content!", detail: paths, style: .information)
                case false?: ui.inform("The two files are different!", detail: paths, style: .information)
                default: ui.inform("The two files could not be compared.", detail: paths, style: .warning)
                }
            }
        }
    }

    /// Asks for a name; nil when the user gave none or kept the proposal's place by cancelling. Main thread.
    private func newName(_ message: String, proposing name: String) -> String? {
        guard let text = ui.prompt(message, value: name)?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
            !text.contains("/")
        else { return nil }
        return text
    }

    func job(_: FileJob, failedAt url: URL, error: Error) -> ErrorChoice {
        monitor.ask {
            ui.pick(
                "Error with \(DisplayName.escaped(url.lastPathComponent))", detail: error.localizedDescription,
                [("Skip", .skip), ("Skip all", .skipAll), ("Retry", .retry), ("Abort", .abort)],
                fallback: ErrorChoice.abort)
        }
    }

    func job(_: FileJob, confirmDeleteNonEmpty directory: URL) -> FolderDeleteChoice {
        monitor.ask {
            pick(
                "The directory \(shown(directory)) is not empty!",
                detail: "Do you want to delete it with all its files and subdirectories?",
                [("Delete", .delete), ("All", .all), ("Skip", .skip), ("Cancel", .cancel)],
                fallback: FolderDeleteChoice.cancel, returnPresses: 2)
        }
    }

    func job(_: FileJob, confirm question: ProtectionQuestion) -> ProtectionChoice {
        let text = OperationText.protection(question, path: shown(question.item.url))
        return monitor.ask {
            pick(
                text.message, detail: text.detail,
                [(text.action, .proceed), ("All", .all), ("Skip", .skip), ("Cancel", .cancel)],
                fallback: ProtectionChoice.cancel, returnPresses: 2)
        }
    }

    func job(_: FileJob, mergeInto existing: FileItem, source _: FileItem) -> MergeChoice {
        monitor.ask {
            ui.pick(
                "The folder \(shown(existing.url)) already exists!",
                detail: "Do you want to copy into it? Files with the same names are asked about one by one.",
                [("Merge", .merge), ("All", .mergeAll), ("Skip", .skip), ("Cancel", .cancel)],
                fallback: MergeChoice.cancel)
        }
    }

    /// Skip comes first, so that Return keeps the other volume as it is.
    func job(_: FileJob, crossVolumeAt folder: FileItem, purpose: ProtectionQuestion.Purpose) -> ProtectionChoice {
        let (action, detail) =
            purpose == .move
            ? ("Move its contents", "Moving it would move everything on that volume away. Do you want that?")
            : ("Delete its contents", "Deleting it would delete everything on that volume. Do you want that?")
        return monitor.ask {
            pick(
                "\(shown(folder.url)) is another volume (a mounted disk, disk image or share)!", detail: detail,
                [("Skip", .skip), (action, .proceed), ("All Volumes", .all), ("Cancel", .cancel)],
                fallback: ProtectionChoice.cancel,
                style: .critical, returnPresses: 0)
        }
    }

    /// The button Return presses in the Overwrite dialog: Skip.
    static let overwriteDefault = 2

    /// A question whose first button destroys something (overwrites, deletes for good, empties
    /// another volume): Return presses the button at `safe`, which leaves things as they are,
    /// and the destroying answer has to be chosen. Main thread.
    private func pick<Choice>(
        _ message: String, detail: String, _ choices: [(String, Choice)], fallback: Choice,
        style: QuestionStyle = .warning, returnPresses safe: Int
    ) -> Choice {
        let index = ui.choose(message, detail: detail, buttons: choices.map(\.0), style: style, defaultButton: safe)
        return choices.indices.contains(index) ? choices[index].1 : fallback
    }

    /// A location as questions show it: with whatever could mislead the eye written out.
    private func shown(_ url: URL) -> String {
        DisplayName.escaped(fileSystems.displayPath(url))
    }
}
