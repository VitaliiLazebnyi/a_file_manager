import AFMContracts
import AFMKernel
import AppKit
import Foundation

/// Command names only this plugin uses (spec 17 › Command catalogue).
extension CommandID {
    /// Pack with "Move to archive" ticked.
    static let moveToArchive: CommandID = "cm_MoveToArchive"
    static let testArchive: CommandID = "cm_TestArchive"
    /// Enters the file under the cursor as an archive, whatever its name ends in.
    static let openAsArchive: CommandID = "afm_OpenAsArchive"
}

/// The keys of the Packer page in the settings.
enum ArchiveSettings {
    static let opensAsFolders = "archives.openAsFolders"
    static let extensions = "archives.extensions"
    static let entersAnyFile = "archives.enterAnyFile"
    static let format = "archives.format"
    static let level = "archives.level"
    static let storesPaths = "archives.storePaths"
    static let recurses = "archives.recurse"
    static let verifies = "archives.verify"
    static let datesByNewest = "archives.dateByNewest"
    static let unpackPaths = "archives.unpackPaths"
    static let unpackSeparate = "archives.unpackSeparate"
    static let unpackOverwrite = "archives.unpackOverwrite"

    /// The endings Enter opens as folders.
    ///
    /// Office documents and installer packages are ZIP or XAR files too, but Enter should hand
    /// those to their applications (spec 08 › Opening an archive, `PreferOpenTypes`); "Open as
    /// Archive" still enters them.
    static let defaultExtensions = "zip 7z rar tar gz tgz bz2 tbz tbz2 xz txz jar war cab cpio lha lzh arj z taz"
    static let levels = ["0 (store)", "1 (fastest)", "2", "3", "4", "5", "6 (normal)", "7", "8", "9 (best)"]

    static func options(from settings: any SettingsStore) -> ArchiveOptions {
        var options = ArchiveOptions()
        options.compressionLevel = max(0, min(settings.index(level, default: 6), 9))
        options.opensAsFolders = settings.flag(opensAsFolders, default: true)
        options.entersAnyFile = settings.flag(entersAnyFile, default: true)
        let list = settings.text(extensions, default: defaultExtensions).lowercased()
        options.extensions = Set(
            list.split(whereSeparator: { " ,;".contains($0) })
                .map {
                    String($0.drop(while: { $0 == "*" || $0 == "." }))
                }
        )
        options.verifiesAfterPacking = settings.flag(verifies, default: true)
        options.datesArchiveByNewest = settings.flag(datesByNewest, default: false)
        return options
    }
}

/// The behaviour behind the archive commands: Pack, Unpack, Test, Open as Archive.
///
/// **Threading.** Commands start on the main thread and only prepare there: they read the
/// panels and ask the user. Everything that reads or writes files runs inside a job, on the
/// job's thread, with a progress window and Cancel; the job's completion returns to the main
/// thread to report and to refresh the panels.
@MainActor
final class ArchiveCommands {
    /// Unowned: the kernel owns the plugin, and through it this.
    private unowned let kernel: Kernel
    private let store: ArchiveStore
    /// What "Unpack and Open" hands the unpacked member to; nil opens nothing.
    private let openFile: (@MainActor (URL) -> Bool)?
    /// The event the application is handling now.
    private let currentEvent: @MainActor () -> NSEvent?
    private var environment: ArchiveEnvironment { store.environment }

    init(
        kernel: Kernel,
        store: ArchiveStore,
        openFile: (@MainActor (URL) -> Bool)?,
        currentEvent: @escaping @MainActor () -> NSEvent?
    ) {
        self.kernel = kernel
        self.store = store
        self.openFile = openFile
        self.currentEvent = currentEvent
    }

    /// Hands a file to the application the system opens it with; false when none opened it.
    internal static func openInApplication(_ file: URL) -> Bool {
        NSWorkspace.shared.open(file)
    }

    /// The event the application is handling now.
    internal static func handledEvent() -> NSEvent? {
        NSApp?.currentEvent
    }

    private var ui: any UserInteraction { kernel.interaction }
    private var fileSystems: FileSystemRegistry { kernel.fileSystems }
    private var settings: any SettingsStore { kernel.settings }
    private var source: any PanelHandle { kernel.panels.source }
    private var target: any PanelHandle { kernel.panels.target }

    /// Copies the settings for the working threads; called on the main thread.
    func refreshOptions() {
        environment.options = ArchiveSettings.options(from: settings)
    }

    /// Re-reads the panels after archives were written: the folders given, and every panel
    /// that is inside an archive.
    private func refreshPanels(_ directories: [URL], focus: URL? = nil) {
        let inArchives = kernel.panels.all.map(\.model.directory).filter(ArchiveURL.isArchiveURL)
        kernel.panels.refresh(directories + inArchives, focus: focus)
    }

    // MARK: Entering archives

    /// True while the key being handled is Ctrl+PgDn, which enters any file as an archive
    /// (spec 08 › Opening an archive).
    ///
    /// The key itself belongs to "Open Directory", which sends files to the openers like Enter
    /// does; this is how the opener tells the two apart.
    private var isForcedOpen: Bool {
        guard let event = currentEvent(), event.type == .keyDown else {
            return false
        }
        return event.keyCode == 121 && event.modifierFlags.contains(.control)
    }

    func archiveRoot(for file: URL, isZip: Bool? = nil) -> URL {
        ArchiveURL.make(
            scheme: ArchiveFileSystem.scheme(forArchive: file, fileSystems: fileSystems, isZip: isZip),
            archive: file
        )
    }

    /// The opener for Enter: archives are entered like folders.
    func open(_ file: FileItem, in panel: any PanelHandle) -> Bool {
        let options = environment.options
        guard !file.isDirectory else {
            return false
        }
        let known = options.opensAsFolders && options.extensions.contains(file.ext.lowercased())
        guard known || (options.entersAnyFile && isForcedOpen) else {
            return false
        }
        panel.show(archiveRoot(for: file.url))
        return true
    }

    /// Enter on a file inside an archive shows what the archive knows about it
    /// (spec 08 › Enter on a file inside an archive).
    func showMember(_ file: FileItem, in _: any PanelHandle) -> Bool {
        guard let location = ArchiveURL.location(of: file.url), !file.isDirectory else {
            return false
        }
        let store = self.store
        kernel.jobs.run(
            title: "Reading:",
            work: { monitor in
                (try? store.archive(at: location.archive, cancellation: monitor.cancellation))?
                    .entry(
                        location.innerPath
                    )
            },
            completion: { [self] entry in
                guard let entry else {
                    return
                }
                // Both sizes are what the archive claims; the quotient may be anything.
                let percent = entry.size > 0 ? (Double(entry.packedSize) / Double(entry.size) * 100).rounded() : -1
                let ratio = (0...100_000).contains(percent) ? "\(Int(percent))%" : "–"
                let detail = """
                    \(fileSystems.displayPath(file.url))
                    Size: \(Format.bytes(entry.size)) bytes
                    Packed: \(Format.bytes(entry.packedSize)) bytes (\(ratio))
                    Changed: \(Format.date(entry.modified))
                    Attributes: \(Format.permissions(entry.permissions))\(entry.isEncrypted ? "\nEncrypted" : "")
                    """
                var buttons = ["Unpack and Open", "Close"]
                if kernel.commands[.view] != nil { buttons.insert("View", at: 0) }
                let answer = ui.choose(entry.name, detail: detail, buttons: buttons, style: .information)
                guard buttons.indices.contains(answer) else {
                    return
                }
                switch buttons[answer] {
                case "View":
                    kernel.commands.perform(.view, .location(file.url))

                case "Unpack and Open":
                    unpackAndOpen(file)

                default:
                    break
                }
            }
        )
        return true
    }

    /// Unpacks one member into the temporary folder and hands it to its application.
    private func unpackAndOpen(_ file: FileItem) {
        let (fileSystems, scratch, store) = (self.fileSystems, environment.scratch, self.store)
        kernel.jobs.run(
            title: "Unpacking:",
            work: { monitor -> Result<URL, any Error> in
                Result {
                    let folder = try scratch.newFile("open")
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let local = folder.appendingPathComponent(file.name, isDirectory: false)
                    // Cancel ends the opening of the member (which may lie behind a long stretch
                    // of decompression), a read that hangs, and the reads after it.
                    let reader = try fileSystems.provider(for: file.url)
                        .read(
                            file.url,
                            cancellation: monitor.cancellation
                        )
                    defer { reader.close() }
                    let tie = monitor.cancellation.interrupting(reader)
                    defer { withExtendedLifetime(tie) {} }
                    let output = try OutputFile(creating: local)
                    while let block = try reader.read(upToCount: 1 << 20) { try output.write(block) }
                    try output.close()
                    // The application that opens it must see where the file came from.
                    if let location = ArchiveURL.location(of: file.url) {
                        Quarantine.apply(
                            (try? store.archive(at: location.archive, cancellation: monitor.cancellation))?.quarantine,
                            to: local
                        )
                    }
                    return local
                }
            },
            completion: { [self] result in
                switch result {
                case .success(let local):
                    _ = openFile?(local)

                case .failure(ArchiveError.cancelled):
                    break

                case .failure(let error):
                    ui.report(error, title: "\(file.name) cannot be unpacked!")
                }
            }
        )
    }

    /// Enters the file under the cursor as an archive, whatever it is called.
    ///
    /// The first bytes are read in the background to see whether it is a ZIP, which can be changed.
    func openAsArchive() {
        let panel = source
        guard let file = panel.model.cursorFile else {
            return
        }
        let fileSystems = self.fileSystems
        kernel.jobs.run(
            title: "Opening:",
            work: { monitor -> Bool in
                guard
                    let reader = try? fileSystems.provider(for: file.url)
                        .read(
                            file.url,
                            cancellation: monitor.cancellation
                        )
                else { return false }
                defer { reader.close() }
                let tie = monitor.cancellation.interrupting(reader)
                defer { withExtendedLifetime(tie) {} }
                let head = (try? reader.read(upToCount: 4)) ?? nil
                return head.map { [UInt8]($0.prefix(2)) == [0x50, 0x4B] } ?? false
            },
            completion: { [self] isZip in
                panel.show(archiveRoot(for: file.url, isZip: isZip ? true : nil))
            }
        )
    }

    // MARK: Pack

    /// Splits a prefix such as `tgz:` off a Pack target (spec 08 › Target string).
    nonisolated static func splitPrefix(_ text: String) -> (format: ArchiveFormat?, path: String) {
        guard let colon = text.firstIndex(of: ":"), !text[text.index(after: colon)...].hasPrefix("//") else {
            return (nil, text)
        }
        let prefix = text[..<colon].lowercased()
        guard let format = ArchiveFormat.writable.first(where: { $0.prefix == prefix || $0.defaultExtension == prefix })
        else { return (nil, text) }
        return (format, String(text[text.index(after: colon)...]))
    }

    /// The file name a new archive gets: the typed name with the ending of the chosen format.
    nonisolated static func archiveName(_ typed: String, format: ArchiveFormat) -> String {
        let ext = (typed as NSString).pathExtension.lowercased()
        if format == .zip, ArchiveFileSystem.zipExtensions.contains(ext) {
            return typed
        }
        if let split = ArchiveFormat.splitKnownExtension(typed) {
            return format.extensions.contains(split.ext.lowercased())
                ? typed : split.base + "." + format.defaultExtension
        }
        return typed + "." + format.defaultExtension
    }

    func pack(move: Bool) {
        refreshOptions()
        let model = source.model
        let (items, sourceDirectory, targetDirectory) = (model.operands(), model.directory, target.model.directory)
        guard !items.isEmpty else {
            ui.inform("No files selected!")
            return
        }
        let formats = ArchiveFormat.writable
        let stored = settings.index(ArchiveSettings.format, default: 0)
        let defaultFormat = formats.indices.contains(stored) ? stored : 0
        // The proposal: an archive named after the operand in the target panel's folder; with
        // a ZIP open in the target panel, that archive and the folder shown (spec 08 › Pack dialog).
        var proposal = fileSystems.displayPath(targetDirectory)
        let intoOpenArchive =
            ArchiveURL.location(of: targetDirectory) != nil && targetDirectory.scheme == ArchiveURL.writableScheme
        if !intoOpenArchive {
            let folderName = sourceDirectory.lastPathComponent
            let base =
                items.count == 1
                ? (items[0].isFolder || items[0].baseName.isEmpty ? items[0].name : items[0].baseName)
                : (folderName.isEmpty || folderName == "/" ? "archive" : folderName)
            proposal =
                (proposal.hasSuffix("/") ? proposal : proposal + "/") + base + "."
                + formats[defaultFormat].defaultExtension
        }
        let fields: [FormField] = [
            .text("archive", "Pack \(items.count) file(s) to the archive", proposal),
            .choice("format", "Packer", formats.map(\.title), selected: intoOpenArchive ? 0 : defaultFormat),
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
        guard let answer = ui.form("Pack files", detail: "", fields: fields, buttons: ["OK"]) else {
            return
        }

        var options = PackOptions()
        let (prefixFormat, path) = Self.splitPrefix(
            answer.text("archive").trimmingCharacters(in: .whitespaces)
        )
        // An archive on a server whose address was typed here: the user's own choice of that server.
        kernel.userTyped(location: path, relativeTo: sourceDirectory, proposal: proposal)
        options.format =
            prefixFormat ?? (formats.indices.contains(answer.index("format")) ? formats[answer.index("format")] : .zip)
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
            } else if items.count > 1 {
                // These formats hold one file each (spec 08 › Packer choice).
                options.separateArchives = true
            }
        }
        if answer.flag("encrypt") {
            guard options.format == .zip else {
                ui.inform("Only ZIP archives can be encrypted.", detail: "", style: .warning)
                return
            }
            guard let secret = askNewPassword(detail: Self.encryptionNote) else {
                return
            }
            (options.password, options.encryption) = (secret.password, secret.encryption)
        }

        // Where the archive goes. A path that runs through an existing ZIP adds to it.
        var archive = ArchiveURL.resolved(
            fileSystems.location(from: path.isEmpty ? "." : path, relativeTo: sourceDirectory)
        )
        var innerFolder = ""
        if let location = ArchiveURL.location(of: archive) {
            guard archive.scheme == ArchiveURL.writableScheme else {
                ui.inform(
                    "\(location.archive.lastPathComponent) cannot be changed.",
                    detail: "Only ZIP archives can be added to.",
                    style: .warning
                )
                return
            }
            (archive, innerFolder, options.format, options.separateArchives) = (
                location.archive, location.innerPath, .zip, false
            )
        } else if path.isEmpty || path.hasSuffix("/") || path == "." {
            archive = archive.appending(name: Packer.archiveName(for: items[0], format: options.format))
        } else {
            archive = archive.deletingLastPathComponent()
                .appending(
                    name: Self.archiveName(archive.lastPathComponent, format: options.format)
                )
        }

        model.saveSelection()
        let (fileSystems, store, ui) = (self.fileSystems, self.store, self.ui)
        kernel.jobs.run(
            title: "Packing:",
            work: { [options, archive, innerFolder] monitor -> (result: PackResult, packed: [String]) in
                let packer = Packer(fileSystems: fileSystems, store: store, monitor: monitor, options: options)
                packer.confirmReplace = { existing in
                    // `@Sendable`, so that it may be sent from this thread to the main thread.
                    monitor.ask { @Sendable in
                        ui.choose(
                            "Overwrite:",
                            detail: "\(fileSystems.displayPath(existing)) already exists.",
                            buttons: ["Overwrite", "Cancel"],
                            style: .warning
                        ) == 0
                    }
                }
                let result = packer.run(items, archive: archive, innerFolder: innerFolder)
                // Which of a hundred thousand operands were packed is worked out here, not on
                // the main thread.
                return (result, Self.names(of: items, packedAs: result.completed))
            },
            completion: { [self] outcome in
                let result = outcome.result
                if let failure = result.failure { ui.report(failure, title: "Packing failed!") }
                model.deselect(outcome.packed)
                // No message on success: the new archive appears in the panel (spec 08 › After packing).
                let written = result.archives.map { $0.deletingLastPathComponent() }
                refreshPanels(
                    written + [archive.deletingLastPathComponent(), sourceDirectory],
                    focus: result.archives.first
                )
            }
        )
    }

    /// The names the panel marks the operands that were packed with.
    ///
    /// A branch or list view names its items by path, which is not the last name of their
    /// locations.
    nonisolated static func names(of operands: [FileItem], packedAs completed: [URL]) -> [String] {
        let packed = Set(completed)
        return operands.filter { packed.contains($0.url) }.map(\.name)
    }

    nonisolated static let encryptionNote =
        "The archive is encrypted with AES-256. 7-Zip, WinZip, Keka and The Unarchiver open it; "
        + "the old unzip program and the Finder do not."
    nonisolated static let legacyLabel =
        "Use the old ZIP encryption instead (weak: it can be broken within minutes; "
        + "only for programs that cannot open AES)"

    /// Asks twice for the password of a new archive, and how to encrypt; nil on Cancel.
    ///
    /// The old encryption is offered for exchange with old programs, and is said to be weak. A
    /// password that is empty, or typed differently the second time, is asked for again.
    private func askNewPassword(detail: String) -> (password: String, encryption: ZipEncryption)? {
        let fields: [FormField] = [
            .password("password", "Password:"), .password("repeat", "Repeat password:"),
            .checkbox("legacy", Self.legacyLabel)
        ]
        guard let answer = ui.form("Encrypt", detail: detail, fields: fields, buttons: ["OK"]) else {
            return nil
        }
        let password = answer.text("password")
        if !password.isEmpty, password == answer.text("repeat") {
            return (password, answer.flag("legacy") ? .legacy : .aes256)
        }
        let problem = password.isEmpty ? "The password must not be empty." : "The two passwords are not the same."
        return askNewPassword(detail: problem + "\n\n" + Self.encryptionNote)
    }

    // MARK: Unpack

    func unpack() {
        refreshOptions()
        let model = source.model
        // (Whether and how many are marked is asked as such: the set of all marked names is not built.)
        let (directory, marked, items) = (model.directory, model.selectionCount, model.operands())
        let inside = ArchiveURL.location(of: directory)
        guard inside != nil || !items.isEmpty else {
            ui.inform("No files selected!", detail: "", style: .warning)
            return
        }
        let fields: [FormField] = [
            .text(
                "target",
                inside == nil ? "Unpack specific files from archive to:" : "Unpack \(max(marked, 1)) file(s) to",
                fileSystems.displayPath(target.model.directory)
            ),
            .text("mask", "Files to unpack:", "*.*"),
            .checkbox(
                "paths",
                "Unpack path names if stored with files",
                settings.flag(ArchiveSettings.unpackPaths, default: true)
            ),
            .checkbox(
                "separate",
                "Unpack each archive to a separate subdir (name of the archive)",
                settings.flag(ArchiveSettings.unpackSeparate, default: false)
            ),
            .checkbox(
                "overwrite",
                "Overwrite existing files",
                settings.flag(ArchiveSettings.unpackOverwrite, default: false)
            )
        ]
        guard let answer = ui.form("Unpack files", detail: "", fields: fields, buttons: ["OK"]) else {
            return
        }
        var options = UnpackOptions()
        options.mask = answer.text("mask").trimmingCharacters(in: .whitespaces).isEmpty ? "*.*" : answer.text("mask")
        options.keepsPaths = answer.flag("paths")
        options.separateFolders = answer.flag("separate")
        options.overwrites = answer.flag("overwrite")
        // An empty target means the archive's own folder (spec 08 › Fields and options).
        let ownFolder = inside.map { $0.archive.deletingLastPathComponent() } ?? directory
        let text = answer.text("target").trimmingCharacters(in: .whitespaces)
        kernel.userTyped(
            location: text,
            relativeTo: ownFolder,
            proposal: fileSystems.displayPath(target.model.directory)
        )
        let targetURL =
            text.isEmpty ? ownFolder : ArchiveURL.resolved(fileSystems.location(from: text, relativeTo: ownFolder))

        model.saveSelection()
        let (fileSystems, store, ui) = (self.fileSystems, self.store, self.ui)
        kernel.jobs.run(
            title: "Unpacking:",
            work: { [options] monitor -> UnpackResult in
                var sources: [Unpacker.Source] = []
                var unreadable: [String] = []
                if let inside {
                    do {
                        // Inside an archive: the marked entries, or everything below the folder shown.
                        let paths = marked == 0 ? nil : items.map { ArchiveTree.join(inside.innerPath, $0.name) }
                        try store.flush(inside.archive, cancellation: monitor.cancellation)
                        sources.append(
                            Unpacker.Source(
                                archive: try store.archive(at: inside.archive, cancellation: monitor.cancellation),
                                base: inside.innerPath,
                                selection: paths
                            )
                        )
                    } catch {
                        unreadable.append(error.localizedDescription)
                    }
                } else {
                    for item in items where !item.isDirectory {
                        do {
                            try store.flush(item.url, cancellation: monitor.cancellation)
                            sources.append(
                                Unpacker.Source(
                                    archive: try store.archive(at: item.url, cancellation: monitor.cancellation)
                                )
                            )
                        } catch {
                            unreadable.append("\(item.name): \(error.localizedDescription)")
                        }
                    }
                }
                let unpacker = Unpacker(fileSystems: fileSystems, monitor: monitor, options: options) {
                    existing,
                    entry in
                    // `@Sendable`, so that it may be sent from this thread to the main thread.
                    monitor.ask { @Sendable in
                        ui.pick(
                            "Overwrite:",
                            detail:
                                "\(fileSystems.displayPath(existing.url))\n\(Format.bytes(existing.size)) bytes, \(Format.date(existing.modified))"
                                + "\n\nWith file:\n\(entry.path)\n\(Format.bytes(entry.size)) bytes, \(Format.date(entry.modified))",
                            [
                                ("Overwrite", .overwrite), ("Overwrite all", .overwriteAll), ("Skip", .skip),
                                ("Skip all", .skipAll), ("Cancel", .cancel)
                            ],
                            fallback: UnpackConflictChoice.cancel
                        )
                    }
                }
                var result = unpacker.run(sources, into: targetURL)
                result.problems = unreadable + result.problems
                return result
            },
            completion: { [self] result in
                if !result.problems.isEmpty {
                    let shown = Self.summary(of: result.problems)
                    ui.inform(
                        result.unpacked > 0 ? "Some files could not be unpacked!" : "Unpacking failed!",
                        detail: shown,
                        style: .warning
                    )
                } else if !result.cancelled {
                    model.deselect(items.map(\.name))
                }
                refreshPanels([targetURL], focus: options.separateFolders ? nil : result.firstTarget)
            }
        )
    }

    /// The first problems of a longer list, for a message box.
    nonisolated internal static func summary(of problems: [String]) -> String {
        problems.prefix(12).joined(separator: "\n") + (problems.count > 12 ? "\n… and \(problems.count - 12) more" : "")
    }

    // MARK: Test

    func test() {
        refreshOptions()
        let model = source.model
        var archives = model.operands().filter { !$0.isDirectory }.map(\.url)
        // Inside an archive the archive itself is tested.
        if let inside = ArchiveURL.location(of: model.directory) { archives = [inside.archive] }
        guard !archives.isEmpty else {
            ui.inform("No files selected!", detail: "", style: .warning)
            return
        }
        let (fileSystems, store) = (self.fileSystems, self.store)
        kernel.jobs.run(
            title: "Testing:",
            work: { [archives] monitor -> (problems: [String], tested: Int) in
                var problems: [String] = []
                var tested = 0
                for (index, url) in archives.enumerated() where !monitor.cancellation.isCancelled {
                    let name = url.lastPathComponent
                    do {
                        try store.flush(url, cancellation: monitor.cancellation)
                        let archive = try store.archive(at: url, cancellation: monitor.cancellation)
                        let members = archive.entries.filter { !$0.isDirectory }
                        let total = members.reduce(Int64(0)) { $0.addingSaturated(max(0, $1.size)) }
                        let counter = SharedCounter()
                        // The password is asked for here, on the job's thread, before the cores share
                        // the work; one that is declined is not asked for again by the test.
                        let found: [String] = try archive.withPasswordScope {
                            try ArchiveTester.unlock(archive)
                            return Background.run(
                                { ArchiveTester.test(archive, cancellation: monitor.cancellation, counter: counter) },
                                tick: {
                                    monitor.report(
                                        JobProgress(
                                            lines: ["Testing: \(fileSystems.displayPath(url))"],
                                            itemsDone: index,
                                            itemsTotal: archives.count,
                                            bytesDone: counter.value,
                                            bytesTotal: total
                                        )
                                    )
                                }
                            )
                        }
                        problems += found.map { "\(name): \($0)" }
                        tested += 1
                    } catch {
                        problems.append("\(name): \(error.localizedDescription)")
                    }
                }
                return (problems, tested)
            },
            completion: { [ui] result in
                if result.problems.isEmpty {
                    ui.inform(
                        "Archive test",
                        detail: "No errors found in \(result.tested) archive(s).",
                        style: .information
                    )
                } else {
                    let shown = Self.summary(of: result.problems)
                    ui.inform("Errors found in archive!", detail: shown, style: .critical)
                }
            }
        )
    }
}
