import AFMKernel
import AppKit

/// Selection files and the clipboard: the selection saved as a list of names, and selected from one.
extension Selections {
    /// How a job with a selection file ended.
    private enum FileOutcome {
        /// Cancelled by the user, or the user chose not to overwrite.
        case cancelled
        /// Done; the folder of the file is read again.
        case done
        /// Failed with that error, which is reported.
        case failed(any Error)
    }

    /// Saving a selection file, as the job does it on its own thread.
    private struct FileSave: Sendable {
        let fileSystems: FileSystemRegistry
        let interaction: any UserInteraction
        let target: URL
        /// The marked entries, picked out in the job (a long selection).
        let operands: PanelModel.Operands
        let encoding: SelectionFile.Encoding

        /// Writes the file; a temporary file of a write that failed is removed.
        func run(_ monitor: any JobMonitor) -> FileOutcome {
            var temporary: URL?
            do {
                return try write(monitor, temporary: &temporary)
            } catch {
                if let temporary, let provider = try? fileSystems.provider(for: temporary) {
                    try? provider.remove(temporary)
                }
                // A write ended by cancelling the job is no failure to report.
                return monitor.cancellation.isCancelled ? .cancelled : .failed(error)
            }
        }

        /// Writes the text beside the target and moves it into place when complete: a write that
        /// fails leaves the old file as it was. `temporary` is the file written beside it.
        private func write(_ monitor: any JobMonitor, temporary: inout URL?) throws -> FileOutcome {
            let provider = try fileSystems.provider(for: target)
            let replaces = provider.item(at: target) != nil
            if replaces, !confirmsOverwrite(monitor) {
                return .cancelled
            }
            let data = SelectionFile.encode(operands.items(), as: encoding)
            let beside = target.deletingLastPathComponent()
                .appending(name: ".\(target.lastPathComponent).afm-\(UUID().uuidString.prefix(8)).tmp")
            temporary = beside
            let writer = try provider.write(beside, cancellation: monitor.cancellation)
            try withExtendedLifetime(monitor.cancellation.interrupting(writer)) {
                try writer.write(data)
                try writer.close(attributes: FileAttributes())
            }
            guard !monitor.cancellation.isCancelled else {
                try? provider.remove(beside)
                return .cancelled
            }
            do {
                try provider.move(beside, to: target, replacing: replaces)
            } catch  where replaces {
                // A file system that cannot replace in one step: the old file goes, the
                // complete new one is moved in at once.
                try provider.remove(target)
                try provider.move(beside, to: target, replacing: false)
            }
            return .done
        }

        /// Asks the user whether the existing target may be overwritten.
        private func confirmsOverwrite(_ monitor: any JobMonitor) -> Bool {
            monitor.ask { @MainActor @Sendable in
                interaction.choose(
                    "\(fileSystems.displayPath(target)) already exists.",
                    detail: "Do you want to overwrite it?",
                    buttons: ["Overwrite", "Cancel"],
                    style: .warning
                ) == 0
            }
        }
    }

    /// The entries a text of names stands for: the ones whose name is written exactly like a
    /// line, and, for a line no entry is written like, the ones that read the same.
    internal struct ListedNames {
        private var exact = Set<NameBytes>()
        private var alike = Set<String>()

        /// Whether the text stands for no entry.
        internal var isEmpty: Bool { exact.isEmpty && alike.isEmpty }

        /// The entries among `items` that the lines of `text` stand for.
        internal init(_ text: String, among items: [FileItem]) {
            let known = Set(items.map(\.name))
            let written = Set(items.map { NameBytes($0.name) })
            for name in SelectionFile.listed(in: text, among: known) {
                if written.contains(NameBytes(name)) { exact.insert(NameBytes(name)) } else { alike.insert(name) }
            }
        }

        /// Whether the text stands for this entry.
        internal func contains(_ item: FileItem) -> Bool {
            exact.contains(NameBytes(item.name)) || (!alike.isEmpty && alike.contains(item.name))
        }
    }

    /// Selection files are small; a file that is not one is not read to its end.
    nonisolated private static let readLimit = 32 << 20

    /// The most text taken from the clipboard as a list of names.
    private static let clipboardLimit = 64 << 20

    /// The bytes of a selection file, at most `readLimit` of them; on the job's thread.
    ///
    /// A read blocked on a server ends when `cancellation` is set.
    nonisolated private static func read(
        _ url: URL,
        from fileSystems: FileSystemRegistry,
        cancellation: CancellationFlag
    ) throws -> Data {
        let reader = try fileSystems.provider(for: url).read(url, cancellation: cancellation)
        defer { reader.close() }
        return try withExtendedLifetime(cancellation.interrupting(reader)) {
            var data = Data()
            while data.count < readLimit, !cancellation.isCancelled, let block = try reader.read(upToCount: 1 << 20) {
                data.append(autoreleasepool { block })
            }
            return data
        }
    }

    /// The file a command names in its argument, or the one the user types; plain names are
    /// files of the source panel's folder.
    private func file(
        from argument: CommandArgument,
        prompt: String,
        proposal: String,
        detail: String,
        directory: URL
    ) -> URL? {
        if let url = argument.location {
            return url
        }
        guard
            let text = (argument.text ?? interaction.prompt(prompt, value: proposal, detail: detail))?
                .trimmingCharacters(in: .whitespaces),
            !text.isEmpty
        else { return nil }
        return kernel.fileSystems.location(from: text, relativeTo: directory)
    }

    /// Save Selection To File (spec 03 › Selection files): the selected names, or the name
    /// under the cursor, written through the file system the file lies on.
    ///
    /// The text is made and written in the job; the old file stays until the new one is complete.
    internal func saveToFile(_ encoding: SelectionFile.Encoding, argument: CommandArgument) {
        let model = source
        // The marked entries are picked out in the job, not here (a long selection).
        // Offered only where there are operands.
        let (operands, directory) = (model.operandsSnapshot(), model.directory)
        let fileSystems = kernel.fileSystems
        guard
            var url = file(
                from: argument,
                prompt: "Save selection to file",
                proposal: "",
                detail:
                    "File name in \(fileSystems.displayPath(directory)); .txt is added to a name without extension.",
                directory: directory
            )
        else { return }
        if url.pathExtension.isEmpty { url = url.appendingPathExtension("txt") }
        let save = FileSave(
            fileSystems: fileSystems,
            interaction: interaction,
            target: url,
            operands: operands,
            encoding: encoding
        )
        kernel.jobs.run(
            title: "Saving selection:",
            work: { monitor in save.run(monitor) },
            completion: { [kernel] outcome in
                switch outcome {
                case .failed(let error):
                    kernel.interaction.report(error, title: "The selection cannot be saved!")

                case .done:
                    kernel.panels.refresh([save.target.deletingLastPathComponent()])

                case .cancelled:
                    break
                }
            }
        )
    }

    /// Load Selection From File: selects exactly the listed names that the panel shows.
    ///
    /// The file is read and its names picked out in the job, which ends when it is cancelled; the
    /// entries are then found like those of any mask.
    internal func loadFromFile(argument: CommandArgument) {
        let model = source
        let directory = model.directory
        let proposal = model.cursorFile.flatMap { $0.ext.lowercased() == "txt" ? $0.name : nil } ?? ""
        let fileSystems = kernel.fileSystems
        guard
            let url = file(
                from: argument,
                prompt: "Load selection from file",
                proposal: proposal,
                detail: "File name in \(fileSystems.displayPath(directory)), or a full path.",
                directory: directory
            )
        else { return }
        let items = model.items
        kernel.jobs.run(
            title: "Loading selection:",
            work: { monitor -> Result<ListedNames?, any Error> in
                let result = Result { () throws -> ListedNames? in
                    let data = try Self.read(url, from: fileSystems, cancellation: monitor.cancellation)
                    return ListedNames(SelectionFile.text(from: data), among: items)
                }
                // A cancelled job ends quietly, whatever its reading came to.
                return monitor.cancellation.isCancelled ? .success(nil) : result
            },
            completion: { [weak self, userInteraction = interaction] result in
                switch result {
                case .failure(let error):
                    userInteraction.report(error, title: "The selection cannot be loaded!")

                case .success(let names?):
                    self?.select(names, in: model, directory: directory)

                case .success(nil):
                    break
                }
            }
        )
    }

    /// `cm_LoadSelectionFromClip`: the same with the text on the clipboard.
    ///
    /// The clipboard is read once, on the main thread (the pasteboard is not safe against use from
    /// two threads at once); the lines are matched against the names off the main thread, and the
    /// text may be as big as memory.
    internal func loadFromClipboard() {
        let model = source
        let (items, directory) = (model.items, model.directory)
        guard let text = pasteboard.string(forType: .string), text.utf8.count <= Self.clipboardLimit else {
            kernel.commands.onRejected()
            return
        }
        guard background, items.count > Self.longList || text.utf8.count > Self.longList * 8 else {
            select(ListedNames(text, among: items), in: model, directory: directory)
            return
        }
        DispatchQueue.global(qos: .userInitiated)
            .async { [weak self] in
                let names = autoreleasepool { ListedNames(text, among: items) }
                DispatchQueue.main.async { [weak self] in self?.select(names, in: model, directory: directory) }
            }
    }

    /// Makes the entries the names stand for the selection of the model, if it still shows the
    /// directory the names were found for.
    private func select(_ names: ListedNames, in model: PanelModel, directory: URL) {
        // The panel may have gone elsewhere while the names were found.
        guard model.directory.isSameLocation(as: directory) else {
            return
        }
        if names.isEmpty {
            if model.selectionCount != 0 { model.clearSelection() }
            return
        }
        markMatching(model, .replace, timedOut: nil) { names.contains($0) }
    }
}
