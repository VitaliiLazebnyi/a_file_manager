import AFMKernel
import Foundation

/// Pack and Move to Archive (spec 08 › Pack dialog).
extension ArchiveCommands {
    /// Splits a prefix such as `tgz:` off a Pack target (spec 08 › Target string).
    nonisolated internal static func splitPrefix(_ text: String) -> (format: ArchiveFormat?, path: String) {
        guard let colon = text.firstIndex(of: ":"), !text[text.index(after: colon)...].hasPrefix("//") else {
            return (nil, text)
        }
        let prefix = text[..<colon].lowercased()
        guard let format = ArchiveFormat.writable.first(where: { $0.prefix == prefix || $0.defaultExtension == prefix })
        else { return (nil, text) }
        return (format, String(text[text.index(after: colon)...]))
    }

    /// The file name a new archive gets: the typed name with the ending of the chosen format.
    nonisolated internal static func archiveName(_ typed: String, format: ArchiveFormat) -> String {
        let ext = URL(fileURLWithPath: typed, isDirectory: false).pathExtension.lowercased()
        if format == .zip, ArchiveFileSystem.zipExtensions.contains(ext) {
            return typed
        }
        if let split = ArchiveFormat.splitKnownExtension(typed) {
            return format.extensions.contains(split.ext.lowercased())
                ? typed : split.base + "." + format.defaultExtension
        }
        return typed + "." + format.defaultExtension
    }

    /// The names the panel marks the operands that were packed with.
    ///
    /// A branch or list view names its items by path, which is not the last name of their
    /// locations.
    nonisolated internal static func names(of operands: [FileItem], packedAs completed: [URL]) -> [String] {
        let packed = Set(completed)
        return operands.filter { packed.contains($0.url) }.map(\.name)
    }

    /// Asks where and how to pack the operands of the source panel, then packs them in a job.
    ///
    /// `move` ticks "Move to archive" in the dialog.
    internal func pack(move: Bool) {
        refreshOptions()
        let model = source.model
        let (items, sourceDirectory, targetDirectory) = (model.operands(), model.directory, target.model.directory)
        guard !items.isEmpty else {
            interaction.inform("No files selected!")
            return
        }
        let formats = ArchiveFormat.writable
        let stored = settings.index(ArchiveSettings.format, default: 0)
        let defaultFormat = formats.indices.contains(stored) ? stored : 0
        let intoOpenArchive =
            ArchiveURL.location(of: targetDirectory) != nil && targetDirectory.scheme == ArchiveURL.writableScheme
        let proposal =
            intoOpenArchive
            ? fileSystems.displayPath(targetDirectory)
            : proposedArchive(for: items, in: sourceDirectory, format: formats[defaultFormat])
        let fields = packFields(
            count: items.count,
            proposal: proposal,
            format: intoOpenArchive ? 0 : defaultFormat,
            move: move
        )
        guard let answer = interaction.form("Pack files", detail: "", fields: fields, buttons: ["OK"]) else {
            return
        }
        let (prefixFormat, path) = Self.splitPrefix(answer.text("archive").trimmingCharacters(in: .whitespaces))
        // An archive on a server whose address was typed here: the user's own choice of that server.
        kernel.userTyped(location: path, relativeTo: sourceDirectory, proposal: proposal)
        guard var options = packOptions(from: answer, format: prefixFormat, itemCount: items.count),
            let destination = packDestination(of: path, from: sourceDirectory, first: items[0], options: &options)
        else { return }
        model.saveSelection()
        runPack(items, of: model, into: destination, options: options)
    }

    /// The archive the Pack dialog proposes: named after the operand (or after the folder, for
    /// several) in the target panel's folder (spec 08 › Pack dialog).
    private func proposedArchive(for items: [FileItem], in sourceDirectory: URL, format: ArchiveFormat) -> String {
        let folder = fileSystems.displayPath(target.model.directory)
        let folderName = sourceDirectory.lastPathComponent
        let base =
            items.count == 1
            ? (items[0].isFolder || items[0].baseName.isEmpty ? items[0].name : items[0].baseName)
            : (folderName.isEmpty || folderName == "/" ? "archive" : folderName)
        return (folder.hasSuffix("/") ? folder : folder + "/") + base + "." + format.defaultExtension
    }

    /// The fields of the Pack dialog for `count` operands; `format` is the index of the packer
    /// chosen at first.
    private func packFields(count: Int, proposal: String, format: Int, move: Bool) -> [FormField] {
        [
            .text("archive", "Pack \(count) file(s) to the archive", proposal),
            .choice("format", "Packer", ArchiveFormat.writable.map(\.title), selected: format),
            .choice(
                "level",
                "Compression rate",
                ArchiveSettings.levels,
                selected: environment.options.compressionLevel
            ),
            .checkbox(
                "paths",
                "Also pack path names (only recursed)",
                settings.flag(ArchiveSettings.storesPaths, default: true)
            ),
            .checkbox(
                "recurse",
                "Recursively pack subdirectories",
                settings.flag(ArchiveSettings.recurses, default: true)
            ),
            .checkbox("move", "Move to archive", move),
            .checkbox("separate", "Create separate archives, one per selected file/dir"),
            .checkbox("skipBase", "Leave out base directory when packing folders (separate archives only)"),
            .checkbox("tarFirst", "Create a TAR archive first, then compress (GZ, BZ2, XZ)"),
            .checkbox("encrypt", "Encrypt with a password (ZIP only)")
        ]
    }

    /// The options the Pack dialog's answer gives; nil when packing does not go on.
    ///
    /// `format` is the one a prefix of the target chose. Asks for the password when encryption
    /// was ticked.
    private func packOptions(from answer: FormValues, format: ArchiveFormat?, itemCount: Int) -> PackOptions? {
        let formats = ArchiveFormat.writable
        var options = PackOptions()
        options.format =
            format ?? (formats.indices.contains(answer.index("format")) ? formats[answer.index("format")] : .zip)
        options.level = max(0, min(answer.index("level"), 9))
        options.storesPaths = answer.flag("paths")
        options.recurses = answer.flag("recurse")
        options.movesSources = answer.flag("move")
        options.separateArchives = answer.flag("separate")
        options.skipsBaseFolder = answer.flag("skipBase") && options.separateArchives
        options.verifies = environment.options.verifiesAfterPacking
        options.datesByNewest = environment.options.datesArchiveByNewest
        options.limits = environment.limits
        if case .compressedFile(let codec) = options.format {
            if answer.flag("tarFirst") {
                options.format = .compressedTar(codec)
            } else if itemCount > 1 {
                // These formats hold one file each (spec 08 › Packer choice).
                options.separateArchives = true
            }
        }
        guard answer.flag("encrypt") else {
            return options
        }
        guard options.format == .zip else {
            interaction.inform("Only ZIP archives can be encrypted.", detail: "", style: .warning)
            return nil
        }
        guard let secret = askNewPassword(detail: Self.encryptionNote) else {
            return nil
        }
        (options.password, options.encryption) = (secret.password, secret.encryption)
        return options
    }

    /// Where the archive goes, from the typed `path`; nil when it cannot go there.
    ///
    /// A path that runs through an existing ZIP adds to it (and `options` become those of a ZIP);
    /// a folder gets an archive named after `first`.
    private func packDestination(
        of path: String,
        from sourceDirectory: URL,
        first: FileItem,
        options: inout PackOptions
    ) -> (archive: URL, innerFolder: String)? {
        let archive = ArchiveURL.resolved(
            fileSystems.location(from: path.isEmpty ? "." : path, relativeTo: sourceDirectory)
        )
        if let location = ArchiveURL.location(of: archive) {
            guard archive.scheme == ArchiveURL.writableScheme else {
                interaction.inform(
                    "\(location.archive.lastPathComponent) cannot be changed.",
                    detail: "Only ZIP archives can be added to.",
                    style: .warning
                )
                return nil
            }
            (options.format, options.separateArchives) = (.zip, false)
            return (location.archive, location.innerPath)
        }
        if path.isEmpty || path.hasSuffix("/") || path == "." {
            return (archive.appending(name: Packer.archiveName(for: first, format: options.format)), "")
        }
        let name = Self.archiveName(archive.lastPathComponent, format: options.format)
        return (archive.deletingLastPathComponent().appending(name: name), "")
    }

    /// Packs `items`, the operands of `model`, in a job, then unmarks what was packed and shows
    /// the new archive.
    private func runPack(
        _ items: [FileItem],
        of model: PanelModel,
        into destination: (archive: URL, innerFolder: String),
        options: PackOptions
    ) {
        let sourceDirectory = model.directory
        kernel.jobs.run(
            title: "Packing:",
            work: { [fileSystems, store, interaction] monitor -> (result: PackResult, packed: [String]) in
                let packer = Packer(fileSystems: fileSystems, store: store, monitor: monitor, options: options)
                packer.confirmReplace = { existing in
                    // `@Sendable`, so that it may be sent from this thread to the main thread.
                    monitor.ask { @Sendable in
                        interaction.choose(
                            "Overwrite:",
                            detail: "\(fileSystems.displayPath(existing)) already exists.",
                            buttons: ["Overwrite", "Cancel"],
                            style: .warning
                        ) == 0
                    }
                }
                let result = packer.run(items, archive: destination.archive, innerFolder: destination.innerFolder)
                // Which of a hundred thousand operands were packed is worked out here, not on
                // the main thread.
                return (result, Self.names(of: items, packedAs: result.completed))
            },
            completion: { [self] outcome in
                let result = outcome.result
                if let failure = result.failure { interaction.report(failure, title: "Packing failed!") }
                model.deselect(outcome.packed)
                // No message on success: the new archive appears in the panel (spec 08 › After packing).
                let written = result.archives.map { $0.deletingLastPathComponent() }
                refreshPanels(
                    written + [destination.archive.deletingLastPathComponent(), sourceDirectory],
                    focus: result.archives.first
                )
            }
        )
    }

    /// Asks twice for the password of a new archive, and how to encrypt; nil on Cancel.
    ///
    /// The old encryption is offered for exchange with old programs, and is said to be weak. A
    /// password that is empty, or typed differently the second time, is asked for again.
    private func askNewPassword(detail: String) -> (password: String, encryption: ZipEncryption)? {
        let fields: [FormField] = [
            .password("password", "Password:"), .password("repeat", "Repeat password:"),
            .checkbox("legacy", Self.legacyLabel)
        ]
        guard let answer = interaction.form("Encrypt", detail: detail, fields: fields, buttons: ["OK"]) else {
            return nil
        }
        let password = answer.text("password")
        if !password.isEmpty, password == answer.text("repeat") {
            return (password, answer.flag("legacy") ? .legacy : .aes256)
        }
        let problem = password.isEmpty ? "The password must not be empty." : "The two passwords are not the same."
        return askNewPassword(detail: problem + "\n\n" + Self.encryptionNote)
    }
}
