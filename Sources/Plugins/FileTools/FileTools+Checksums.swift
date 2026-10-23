import AFMContracts
import AFMKernel
import AppKit

/// Checksums: Create checksum files and Verify checksums.
extension FileTools {
    /// What Verify made of its run: the text of the window, and the names to mark in the panel.
    private struct Verified {
        /// The title of the window: the method and the number of errors.
        var title: String
        /// The text of the window.
        var text: String
        /// The names of the files that failed.
        var failedNames: [String]
        /// How many failed.
        var errors: Int
    }

    /// The folders the checksum files went to, found on the job's thread; one entry each, with its key.
    private struct Created {
        /// The folders, each with its location key.
        var folders: [(url: URL, key: String)]
    }

    /// The folders of the files written, each once, in the order they came, each with its location key.
    nonisolated private static func folders(of written: [URL]) -> [(url: URL, key: String)] {
        var seen = Set<String>()
        var folders: [(url: URL, key: String)] = []
        for url in written {
            let folder = url.deletingLastPathComponent()
            let key = folder.locationKey
            if seen.insert(key).inserted {
                folders.append((folder, key))
            }
        }
        return folders
    }

    /// Create checksum files: asks for the target, the method and the format, and hashes the operands into
    /// checksum files.
    internal func createChecksums() {
        let model = source
        // The operands are made on the job's thread: with 300,000 marks that is a pass over them, and the form needs
        // only how many there are and, for one, its name.
        // Offered only where there are operands: the marked ones, or the item under the cursor.
        let (operands, directory) = (model.operandsSnapshot(), model.directory)
        let count = max(operands.markedCount, 1)
        let firstName = count == 1 ? operands.items().first?.name : nil
        let lastMethod = ChecksumMethod(rawValue: settings.index(Keys.checksumMethod, default: 0)) ?? .crc32
        let proposal = fileSystems.displayPath(
            Self.checksumProposal(count: count, firstName: firstName, in: directory, method: lastMethod)
        )
        let fields = checksumFields(proposal: proposal, lastMethod: lastMethod)
        guard let answer = interaction.form("Create CRC-checksum file", detail: "", fields: fields, buttons: ["OK"])
        else {
            return
        }
        let options = createOptions(from: answer, lastMethod: lastMethod)
        // The dialog cannot change the proposal while a method is chosen; it is done here.
        let typed = answer.text("target").trimmingCharacters(in: .whitespaces)
        kernel.userTyped(location: typed, relativeTo: directory, proposal: proposal)
        var target =
            typed == proposal || typed.isEmpty
            ? Self.checksumProposal(count: count, firstName: firstName, in: directory, method: options.method)
            : fileSystems.location(from: typed, relativeTo: directory)
        if options.separatePerFile, !target.lastPathComponent.contains("*") {
            let pattern = settings.flag(Keys.appendExtension, default: true) ? "*.*." : "*."
            target = target.deletingLastPathComponent().appending(name: pattern + options.method.fileExtension)
        }
        run(
            "Create CRC-checksum file",
            job: "Creating checksums:",
            refreshing: { [kernel] (created: Created?) in
                // A panel shows one folder, so with very many folders only those it shows need reading again.
                guard let folders = created?.folders else {
                    return [directory]
                }
                guard folders.count > 256 else {
                    return [directory] + folders.map(\.url)
                }
                let shown = Set(kernel.panels.all.map(\.model.directory.locationKey))
                return [directory] + folders.filter { folder in shown.contains(folder.key) }.map(\.url)
            },
            { [target, options] run in
                let written = try ChecksumRun.create(for: operands.items(), target: target, options: options, run: run)
                return Created(folders: Self.folders(of: written))
            },
            then: { _ in
                // After creation the source selection is cleared, if the panel still shows the folder it was made in.
                if model.directory.isSameLocation(as: directory) {
                    model.clearSelection()
                }
            }
        )
    }

    /// The fields of the Create checksum files dialog, with the choices last made.
    private func checksumFields(proposal: String, lastMethod: ChecksumMethod) -> [FormField] {
        [
            .text("target", "Save CRC file(s) to:", proposal),
            .checkbox(
                "separateFiles",
                "Create separate checksum files for each file",
                settings.flag(Keys.separateFiles, default: false)
            ),
            .checkbox(
                "separateFolders",
                "Create separate checksum files for each directory",
                settings.flag(Keys.separateFolders, default: false)
            ),
            .checkbox(
                "utf8",
                "Always use UTF-8 in names (with a byte-order mark)",
                settings.flag(Keys.forceUTF8, default: false)
            ),
            .checkbox(
                "unix",
                "Unix format: line breaks, '/' in paths",
                settings.flag(Keys.unixFormat, default: true)
            ),
            .choice(
                "method",
                "Checksum method:",
                ChecksumMethod.dialogOrder.map(\.title),
                selected: lastMethod.dialogPosition
            ),
            .note(
                "The extension follows the method while the proposed name is unchanged. Separate files take a name "
                    + "with *: *.*.sfv adds the extension, *.sfv replaces the file's own."
            )
        ]
    }

    /// The options the user chose in the dialog, remembered for the next time.
    private func createOptions(from answer: FormValues, lastMethod: ChecksumMethod) -> ChecksumRun.CreateOptions {
        var options = ChecksumRun.CreateOptions()
        options.method =
            ChecksumMethod.dialogOrder.indices.contains(answer.index("method"))
            ? ChecksumMethod.dialogOrder[answer.index("method")] : lastMethod
        options.separatePerFile = answer.flag("separateFiles")
        options.separatePerFolder = answer.flag("separateFolders")
        options.alwaysUTF8 = answer.flag("utf8")
        options.unixFormat = answer.flag("unix")
        settings.set(options.method.rawValue, forKey: Keys.checksumMethod)
        settings.set(options.separatePerFile, forKey: Keys.separateFiles)
        settings.set(options.separatePerFolder, forKey: Keys.separateFolders)
        settings.set(options.alwaysUTF8, forKey: Keys.forceUTF8)
        settings.set(options.unixFormat, forKey: Keys.unixFormat)
        return options
    }

    /// Verify checksums: the checksum files among the operands, else the file under the cursor against a
    /// checksum on the clipboard, else files with a CRC32 in their names.
    internal func verifyChecksums() {
        let model = source
        let operands = model.operandsSnapshot()
        let cursor = model.cursorItem
        let extraMasks = settings.text(Keys.extraTypes, default: "")
        let onlyErrors = settings.flag(Keys.onlyErrors, default: false)
        // Asked for in the job, and only when it is needed: the clipboard may be slow to answer.
        // It is read on the main thread all the same (`clipboardText`), which the job waits for.
        let title = "Verify checksums"
        // The sorting out of what the operands are (a mask test per name, the clipboard) and the work
        // itself happen in the job: with a large selection none of it belongs on the main thread.
        verify(title, in: model, onlyErrors: onlyErrors) { [kernel] run in
            let isChecksumFile = ChecksumFile.checksumFileTest(extraMasks: extraMasks)
            let items = operands.items()
            let checksumFiles = items.filter { item in !item.isDirectory && isChecksumFile(item.name) }
            if !checksumFiles.isEmpty {
                return try ChecksumRun.verify(checksumFiles: checksumFiles, run: run)
            }
            if let cursor, !cursor.isDirectory,
                let digest = ChecksumRun.checksum(fromClipboard: kernel.askUser { _ in self.clipboardText() })
            {
                return try ChecksumRun.verify([(cursor, digest)], title: "Checksum from the clipboard", run: run)
            }
            let named = items.compactMap { item in
                ChecksumRun.checksumInName(item.name).map { digest in (item, digest) }
            }
            if !named.isEmpty, named.count == items.count {
                return try ChecksumRun.verify(named, title: "Checksums in the file names", run: run)
            }
            return nil
        }
    }

    /// The text on the clipboard.
    ///
    /// Main thread: `NSPasteboard` is not made for other threads.
    private func clipboardText() -> String? {
        pasteboard.string(forType: .string)
    }

    /// Runs a Verify as a job and shows its report (or says what to select when there was nothing to verify),
    /// marking the failed files in the panel.
    private func verify(
        _ title: String,
        in model: PanelModel,
        onlyErrors: Bool,
        _ work: @escaping @Sendable (ToolRun) throws -> VerifyReport?
    ) {
        let directory = model.directory
        run(
            title,
            job: "Verifying checksums:",
            refreshing: { (_: Verified??) in [] },
            { run -> Verified? in
                guard let report = try work(run) else {
                    return nil
                }
                // Text and names are made here, not in the completion on the main thread.
                return Verified(
                    title: report.title,
                    text: report.text(onlyErrors: onlyErrors),
                    failedNames: report.failedNames,
                    errors: report.errors
                )
            },
            then: { [kernel] verified in
                guard let verified else {
                    return kernel.interaction.inform("Please select only SFV, MD5 or SHA files!")
                }
                // The failures are marked in the panel they were checked from.
                if verified.errors > 0, model.directory.isSameLocation(as: directory) {
                    model.setSelection(names: verified.failedNames)
                }
                if let viewer = kernel.services.find((any ViewerService).self) {
                    viewer.view(text: verified.text, title: verified.title)
                } else {
                    _ = kernel.interaction.form(
                        verified.title,
                        detail: "",
                        fields: [.lines("result", "", verified.text)],
                        buttons: ["Close"]
                    )
                }
            }
        )
    }
}
