import AFMContracts
import AFMKernel
import AppKit

/// The commands of this plugin, under the names of the specification (17 › Command catalogue).
extension CommandID {
    static let splitFile: CommandID = "cm_Split"
    static let combineFiles: CommandID = "cm_Combine"
    static let encodeFile: CommandID = "cm_Encode"
    static let decodeFile: CommandID = "cm_Decode"
    static let createChecksums: CommandID = "cm_CRCcreate"
    static let verifyChecksums: CommandID = "cm_CRCcheck"
}

/// Split, combine, encode, decode and checksums (spec 08).
public final class FileToolsPlugin: Plugin {
    public let name = "FileTools"
    private let pasteboard: NSPasteboard?

    /// `pasteboard` is where Verify looks for a checksum; by default the general pasteboard.
    public init(pasteboard: NSPasteboard? = nil) {
        self.pasteboard = pasteboard
    }

    public func start(in kernel: Kernel) {
        let tools = FileTools(kernel, pasteboard: pasteboard)
        let source = { kernel.panels.source.model }
        let onFile = { source().cursorItem.map { !$0.isDirectory } ?? false }
        let hasOperands = { source().hasOperands }
        let commands = kernel.commands
        commands.register(Command(.splitFile, "Split File…"), enabled: onFile, tools.split)
        commands.register(Command(.combineFiles, "Combine Files…"), enabled: onFile, tools.combine)
        commands.register(Command(.encodeFile, "Encode File (MIME, UUE, XXE)…"), enabled: onFile, tools.encode)
        commands.register(Command(.decodeFile, "Decode File (MIME, UUE, XXE, yEnc)…"), enabled: onFile, tools.decode)
        commands.register(
            Command(.createChecksums, "Create Checksum File(s) (CRC32, MD5, SHA)…"), enabled: hasOperands,
            tools.createChecksums)
        commands.register(Command(.verifyChecksums, "Verify Checksums"), enabled: hasOperands, tools.verifyChecksums)
        kernel.menus.add(
            [.splitFile, .combineFiles, .encodeFile, .decodeFile, .createChecksums, .verifyChecksums],
            to: .filesTransform)
        kernel.menus.addToContextMenu([.createChecksums, .verifyChecksums], in: .tools, onItemOnly: true)
        kernel.toolbar.add(
            .createChecksums, symbol: "number.square", group: 60,
            hint: "Create checksum files (MD5, SHA and others) for the selected files.")
        kernel.toolbar.add(
            .verifyChecksums, symbol: "checkmark.seal", group: 60,
            hint: "Check the selected files against their checksum file, to find damaged copies.")
        kernel.toolbar.setSymbol("scissors", for: .splitFile)
        kernel.toolbar.setSymbol("link", for: .combineFiles)
        kernel.preferences.add(
            PreferencePage(
                title: "File Tools",
                preferences: [
                    Preference(
                        FileTools.Keys.onlyErrors, "Verify checksums: show only the errors", .flag(default: false)),
                    Preference(
                        FileTools.Keys.appendExtension,
                        "Separate checksum files: add the extension to the file's name (off: replace its extension)",
                        .flag(default: true)),
                    Preference(
                        FileTools.Keys.extraTypes, "More masks for checksum files (e.g. *.sum *.crc32)",
                        .text(default: ""))
                ]))
    }
}

/// The behaviour behind the commands.
///
/// **Threading.** A command starts on the main thread, where it reads the panel and asks its
/// dialog. All reading, writing and hashing happens inside a job on the job's thread (hashing
/// on all cores); the job's completion returns to the main thread to report and refresh.
final class FileTools {
    /// The settings keys; the spec's names are given where it has them.
    enum Keys {
        static let scope = "filetools."
        /// `SplitBytesPerFile`, as typed.
        static let splitSize = scope + "splitBytesPerFile"
        /// `EncodeMethod`
        static let encodeMethod = scope + "encodeMethod"
        /// `EncodeLinesPerFile`
        static let encodeLines = scope + "encodeLinesPerFile"
        /// `Lastmd5`
        static let checksumMethod = scope + "lastChecksumMethod"
        /// `CrcSeparateFiles`, `CrcSeparateFolders`, `CrcForceUtf8`, `CrcForwardSlashes`, `CrcAppendExt`
        static let separateFiles = scope + "crcSeparateFiles"
        static let separateFolders = scope + "crcSeparateFolders"
        static let forceUTF8 = scope + "crcForceUtf8"
        static let unixFormat = scope + "crcUnixFormat"
        static let appendExtension = scope + "crcAppendExt"
        /// `ChecksumExtraTypes`
        static let extraTypes = scope + "checksumExtraTypes"
        static let onlyErrors = scope + "verifyOnlyErrors"
    }

    private let kernel: Kernel
    private let pasteboard: NSPasteboard?

    init(_ kernel: Kernel, pasteboard: NSPasteboard?) {
        self.kernel = kernel
        self.pasteboard = pasteboard
    }

    private var source: PanelModel { kernel.panels.source.model }
    private var ui: any UserInteraction { kernel.ui }
    private var settings: any SettingsStore { kernel.settings }
    private var fileSystems: FileSystemRegistry { kernel.fileSystems }

    // MARK: Common

    /// The file under the cursor, or the message of the spec when there is none.
    private func cursorFile() -> FileItem? {
        guard let item = source.cursorItem, !item.isDirectory else {
            ui.inform("No files selected!")
            return nil
        }
        return item
    }

    /// The other panel's folder, as the dialogs propose it.
    private var targetProposal: String { fileSystems.displayPath(kernel.panels.target.model.directory) }

    /// An empty target is the source folder.
    private func folder(from text: String, relativeTo directory: URL) -> URL {
        // A target that was typed (not the proposal left as it was) is the user's own choice of a server, if it names one.
        kernel.userTyped(location: text, proposal: targetProposal, relativeTo: directory)
        return text.trimmingCharacters(in: .whitespaces).isEmpty
            ? directory : fileSystems.location(from: text, relativeTo: directory)
    }

    /// Runs a tool as a job with progress and Cancel. Its error, if any, is shown under
    /// `title`; a cancelled run says nothing. The folders in `refreshing` are read again; it
    /// gets the result of the work (nil when it failed or was cancelled), which was made on the
    /// job's thread and reaches the main thread with the completion.
    private func run<Value>(
        _ title: String, job: String, refreshing folders: @escaping (Value?) -> [URL],
        _ work: @escaping (ToolRun) throws -> Value,
        then done: @escaping (Value) -> Void
    ) {
        let (fileSystems, ui) = (self.fileSystems, self.ui)
        kernel.jobs.run(
            title: job,
            work: { monitor -> Result<Value, any Error> in
                let run = ToolRun(fileSystems: fileSystems, monitor: monitor) { url in
                    ui.pick(
                        "Overwrite:", detail: fileSystems.displayPath(url),
                        [
                            ("Overwrite", .overwrite), ("Overwrite all", .overwriteAll), ("Skip", .skip),
                            ("Cancel", .cancel)
                        ],
                        fallback: ExistingFileChoice.cancel)
                }
                let result = Result { try work(run) }
                // The last state always reaches the progress window, whatever was held back before.
                run.advance(0, force: true)
                return result
            },
            completion: { [kernel] result in
                kernel.panels.refresh(folders(try? result.get()))
                switch result {
                case .success(let value): done(value)
                case .failure(ToolError.cancelled): break
                case .failure(let error): kernel.ui.inform(title, detail: error.localizedDescription, style: .warning)
                }
            })
    }

    /// Creates the target folder of a tool that, like Copy, makes it when it is missing.
    private static func prepare(_ folder: URL, _ run: ToolRun) throws {
        do {
            try run.provider(for: folder).createDirectory(at: folder)
        } catch {
            throw ToolError.failed("The given target path\n\(run.fileSystems.displayPath(folder))\nis invalid!")
        }
    }

    // MARK: Split and combine

    func split() {
        guard let file = cursorFile() else { return }
        let directory = source.directory
        let presets = ["(the size typed above)"] + Splitter.presets.map(\.title)
        let fields: [FormField] = [
            .note("Split the file '\(file.name)' to directory:"), .text("target", "", targetProposal),
            .text("size", "Bytes per file:", settings.text(Keys.splitSize, default: "")),
            .choice("preset", "or a standard size:", presets),
            .note("A size is a number of bytes, or a number with k, M or G (1 k = 1024 bytes).")
        ]
        guard let answer = ui.form("Split", detail: "", fields: fields, buttons: ["OK"]) else { return }
        let preset = answer.index("preset")
        guard let size = preset > 0 ? Splitter.presets[preset - 1].bytes : Splitter.size(from: answer.text("size"))
        else {
            ui.inform("Split", detail: "Please enter the number of bytes per file!", style: .warning)
            return
        }
        if preset <= 0 {
            settings.set(answer.text("size").trimmingCharacters(in: .whitespaces), forKey: Keys.splitSize)
        }
        let target = folder(from: answer.text("target"), relativeTo: directory)
        run(
            "Split", job: "Split:", refreshing: { (_: [URL]?) in [target] },
            { run in
                try Self.prepare(target, run)
                return try Splitter.split(file, into: target, partSize: size, run: run)
            },
            then: { [ui, fileSystems] _ in
                ui.inform(
                    "Split", detail: "Split of \(fileSystems.displayPath(file.url)) succeeded!", style: .information)
            })
    }

    func combine() {
        guard let file = cursorFile() else { return }
        let directory = source.directory
        let fields: [FormField] = [
            .note("Combine \(file.name) and all files with ascending names to the following directory:"),
            .text("target", "", targetProposal)
        ]
        guard let answer = ui.form("Combine", detail: "", fields: fields, buttons: ["OK"]) else { return }
        let target = folder(from: answer.text("target"), relativeTo: directory)
        run(
            "Combine", job: "Combine:", refreshing: { (_: Combiner.Outcome?) in [target] },
            { run -> Combiner.Outcome in
                try Self.prepare(target, run)
                let plan = try Combiner.plan(for: file, run: run)
                return try Combiner.combine(plan.parts, info: plan.info, into: target, run: run)
            },
            then: { [ui] outcome in
                let name = outcome.output.lastPathComponent
                switch outcome.verified {
                case true?:
                    ui.inform(
                        "Combine - \(outcome.parts)", detail: "Combine of \(name) succeeded (CRC checksum OK)!",
                        style: .information)

                case false?:
                    ui.inform(
                        "Combine - \(outcome.parts)",
                        detail: "Combine of \(name): CRC checksum error! The file is damaged or incomplete.",
                        style: .critical)

                case nil:
                    ui.inform(
                        "Combine - \(outcome.parts)", detail: "Combine of \(name) succeeded!", style: .information)
                }
            })
    }

    // MARK: Encode and decode

    func encode() {
        guard let file = cursorFile() else { return }
        let directory = source.directory
        let lastLines = settings.index(Keys.encodeLines, default: 0)
        let fields: [FormField] = [
            .note("Encode the file \(file.name) to directory:"), .text("target", "", targetProposal),
            .choice(
                "method", "Encode as:", EncodeMethod.allCases.map(\.title),
                selected: settings.index(Keys.encodeMethod, default: 0)),
            .text("lines", "Lines per file:", lastLines > 0 ? String(lastLines) : ""),
            .text("bytes", "Bytes per file:", ""),
            .note("(Note: header size is not counted)")
        ]
        guard let answer = ui.form("Encode", detail: "", fields: fields, buttons: ["OK"]) else { return }
        let method = EncodeMethod(rawValue: answer.index("method")) ?? .mime
        let lines = max(0, Int(answer.text("lines").trimmingCharacters(in: .whitespaces)) ?? 0)
        let bytes = Splitter.size(from: answer.text("bytes")) ?? 0
        settings.set(method.rawValue, forKey: Keys.encodeMethod)
        settings.set(lines, forKey: Keys.encodeLines)
        let target = folder(from: answer.text("target"), relativeTo: directory)
        run(
            "Encode", job: "Encode:", refreshing: { (_: [URL]?) in [target] },
            { run in
                try Self.prepare(target, run)
                return try Encoder.encode(
                    file, into: target, method: method, linesPerFile: lines, bytesPerFile: bytes, run: run)
            }, then: { _ in })
    }

    func decode() {
        guard let file = cursorFile() else { return }
        let directory = source.directory
        let fields: [FormField] = [
            .note("Decode the file \(file.name) to directory:"), .text("target", "", targetProposal),
            .checkbox("autoRename", "Auto-rename decoded files")
        ]
        guard let answer = ui.form("Decode", detail: "", fields: fields, buttons: ["OK"]) else { return }
        let target = folder(from: answer.text("target"), relativeTo: directory)
        let autoRename = answer.flag("autoRename")
        run(
            "Decode", job: "Decode:", refreshing: { (_: Decoder.Outcome?) in [target] },
            { run in
                // Unlike Copy, Decode does not create a missing target folder.
                guard run.fileSystems.item(at: target)?.isDirectory == true else {
                    throw ToolError.failed("The given target path\n\(run.fileSystems.displayPath(target))\nis invalid!")
                }
                return try Decoder.decodeChecked(file, into: target, autoRename: autoRename, run: run)
            },
            then: { [ui, fileSystems] outcome in
                // The files are kept; what the encoded text itself shows to be wrong is said.
                guard !outcome.problems.isEmpty else { return }
                let shown = outcome.problems.prefix(8).map { "- " + $0 }.joined(separator: "\n")
                let more = outcome.problems.count > 8 ? "\n... and \(outcome.problems.count - 8) more" : ""
                let folder = fileSystems.displayPath(target)
                ui.inform(
                    "Decode",
                    detail:
                        "\(file.name) is incomplete or damaged:\n\(shown)\(more)\n\nThe decoded data was written to \(folder) as far as it could be read.",
                    style: .warning)
            })
    }

    // MARK: Checksums

    /// The proposal of "Save CRC file(s) to": next to the one file under its name, or, for
    /// several items, in the source folder under the folder's name.
    static func checksumProposal(for operands: [FileItem], in directory: URL, method: ChecksumMethod) -> URL {
        checksumProposal(count: operands.count, firstName: operands.first?.name, in: directory, method: method)
    }

    /// The same from how many items there are and the name of the first, which is all it needs.
    static func checksumProposal(count: Int, firstName: String?, in directory: URL, method: ChecksumMethod) -> URL {
        let name =
            count == 1
            ? firstName ?? "" : (directory.lastPathComponent == "/" ? "checksums" : directory.lastPathComponent)
        return directory.appending(name: (name.isEmpty ? "checksums" : name) + "." + method.fileExtension)
    }

    func createChecksums() {
        let model = source
        // The operands are made on the job's thread: with 300,000 marks that is a pass over them, and the form needs
        // only how many there are and, for one, its name.
        let (operands, directory) = (model.operandsSnapshot(), model.directory)
        let count = operands.markedCount > 0 ? operands.markedCount : (operands.cursorItem == nil ? 0 : 1)
        guard count > 0 else {
            ui.inform("No files selected!")
            return
        }
        let firstName = count == 1 ? operands.items().first?.name : nil
        let lastMethod = ChecksumMethod(rawValue: settings.index(Keys.checksumMethod, default: 0)) ?? .crc32
        let proposal = fileSystems.displayPath(
            Self.checksumProposal(count: count, firstName: firstName, in: directory, method: lastMethod))
        let fields: [FormField] = [
            .text("target", "Save CRC file(s) to:", proposal),
            .checkbox(
                "separateFiles", "Create separate checksum files for each file",
                settings.flag(Keys.separateFiles, default: false)),
            .checkbox(
                "separateFolders", "Create separate checksum files for each directory",
                settings.flag(Keys.separateFolders, default: false)),
            .checkbox(
                "utf8", "Always use UTF-8 in names (with a byte-order mark)",
                settings.flag(Keys.forceUTF8, default: false)),
            .checkbox(
                "unix", "Unix format: line breaks, '/' in paths", settings.flag(Keys.unixFormat, default: true)),
            .choice(
                "method", "Checksum method:", ChecksumMethod.dialogOrder.map(\.title),
                selected: ChecksumMethod.dialogOrder.firstIndex(of: lastMethod) ?? 0),
            .note(
                "The extension follows the method while the proposed name is unchanged. Separate files take a name with *: "
                    + "*.*.sfv adds the extension, *.sfv replaces the file's own.")
        ]
        guard let answer = ui.form("Create CRC-checksum file", detail: "", fields: fields, buttons: ["OK"]) else {
            return
        }
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

        // The dialog cannot change the proposal while a method is chosen; it is done here.
        let typed = answer.text("target").trimmingCharacters(in: .whitespaces)
        kernel.userTyped(location: typed, proposal: proposal, relativeTo: directory)
        var target =
            typed == proposal || typed.isEmpty
            ? Self.checksumProposal(count: count, firstName: firstName, in: directory, method: options.method)
            : fileSystems.location(from: typed, relativeTo: directory)
        if options.separatePerFile, !target.lastPathComponent.contains("*") {
            let pattern = settings.flag(Keys.appendExtension, default: true) ? "*.*." : "*."
            target = target.deletingLastPathComponent().appending(name: pattern + options.method.fileExtension)
        }
        /// The folders the checksum files went to, found on the job's thread; one entry each, with its key.
        struct Created { var folders: [(url: URL, key: String)] }
        run(
            "Create CRC-checksum file", job: "Creating checksums:",
            refreshing: { [kernel] (created: Created?) in
                // A panel shows one folder, so with very many folders only those it shows need reading again.
                guard let folders = created?.folders else { return [directory] }
                guard folders.count > 256 else { return [directory] + folders.map(\.url) }
                let shown = Set(kernel.panels.all.map { $0.model.directory.locationKey })
                return [directory] + folders.filter { shown.contains($0.key) }.map(\.url)
            },
            { run in
                let written = try ChecksumRun.create(for: operands.items(), target: target, options: options, run: run)
                var seen = Set<String>()
                var folders: [(url: URL, key: String)] = []
                for url in written {
                    let folder = url.deletingLastPathComponent()
                    let key = folder.locationKey
                    if seen.insert(key).inserted { folders.append((folder, key)) }
                }
                return Created(folders: folders)
            },
            then: { _ in
                // After creation the source selection is cleared, if the panel still shows the folder it was made in.
                if model.directory.isSameLocation(as: directory) { model.clearSelection() }
            })
    }

    /// What Verify made of its run: the text of the window, and the names to mark in the panel.
    private struct Verified {
        var title: String
        var text: String
        var failedNames: [String]
        var errors: Int
    }

    func verifyChecksums() {
        let model = source
        let operands = model.operandsSnapshot()
        let cursor = model.cursorItem
        let extraMasks = settings.text(Keys.extraTypes, default: "")
        let onlyErrors = settings.flag(Keys.onlyErrors, default: false)
        let pasteboard = self.pasteboard
        let title = "Verify checksums"
        // The sorting out of what the operands are (a mask test per name, the clipboard) and the work
        // itself happen in the job: with a large selection none of it belongs on the main thread.
        verify(title, in: model, onlyErrors: onlyErrors) { run in
            let isChecksumFile = ChecksumFile.checksumFileTest(extraMasks: extraMasks)
            let operands = operands.items()
            let checksumFiles = operands.filter { !$0.isDirectory && isChecksumFile($0.name) }
            if !checksumFiles.isEmpty { return try ChecksumRun.verify(checksumFiles: checksumFiles, run: run) }
            if let cursor, !cursor.isDirectory,
                let digest = ChecksumRun.checksum(fromClipboard: (pasteboard ?? .general).string(forType: .string))
            {
                return try ChecksumRun.verify([(cursor, digest)], title: "Checksum from the clipboard", run: run)
            }
            let named = operands.compactMap { item in ChecksumRun.checksumInName(item.name).map { (item, $0) } }
            if !named.isEmpty, named.count == operands.count {
                return try ChecksumRun.verify(named, title: "Checksums in the file names", run: run)
            }
            return nil
        }
    }

    private func verify(
        _ title: String, in model: PanelModel, onlyErrors: Bool, _ work: @escaping (ToolRun) throws -> VerifyReport?
    ) {
        let directory = model.directory
        run(
            title, job: "Verifying checksums:", refreshing: { (_: Verified??) in [] },
            { run -> Verified? in
                guard let report = try work(run) else { return nil }
                // Text and names are made here, not in the completion on the main thread.
                return Verified(
                    title: report.title, text: report.text(onlyErrors: onlyErrors), failedNames: report.failedNames,
                    errors: report.errors)
            },
            then: { [kernel] verified in
                guard let verified else { return kernel.ui.inform("Please select only SFV, MD5 or SHA files!") }
                // The failures are marked in the panel they were checked from.
                if verified.errors > 0, model.directory.isSameLocation(as: directory) {
                    model.setSelection(names: verified.failedNames)
                }
                if let viewer = kernel.services.find((any ViewerService).self) {
                    viewer.view(text: verified.text, title: verified.title)
                } else {
                    _ = kernel.ui.form(
                        verified.title, detail: "", fields: [.lines("result", "", verified.text)], buttons: ["Close"])
                }
            })
    }
}
