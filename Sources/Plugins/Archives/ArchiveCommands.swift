import AFMContracts
import AFMKernel
import AppKit
import Foundation

/// The behaviour behind the archive commands: Pack, Unpack, Test, Open as Archive.
///
/// **Threading.** Commands start on the main thread and only prepare there: they read the
/// panels and ask the user. Everything that reads or writes files runs inside a job, on the
/// job's thread, with a progress window and Cancel; the job's completion returns to the main
/// thread to report and to refresh the panels.
@MainActor
internal final class ArchiveCommands {
    /// What the password dialog of a new archive says about the encryption.
    nonisolated internal static let encryptionNote =
        "The archive is encrypted with AES-256. 7-Zip, WinZip, Keka and The Unarchiver open it; "
        + "the old unzip program and the Finder do not."
    /// The label of the box that picks the old ZIP encryption.
    nonisolated internal static let legacyLabel =
        "Use the old ZIP encryption instead (weak: it can be broken within minutes; "
        + "only for programs that cannot open AES)"

    /// The kernel the commands work in.
    ///
    /// Unowned: the kernel owns the plugin, and through it this.
    internal unowned let kernel: Kernel
    /// The open archives, shared with the file systems.
    internal let store: ArchiveStore
    /// What "Unpack and Open" hands the unpacked member to; nil opens nothing.
    private let openFile: (@MainActor (URL) -> Bool)?
    /// The event the application is handling now.
    private let currentEvent: @MainActor () -> NSEvent?
    /// The settings and limits shared with the working threads.
    internal var environment: ArchiveEnvironment { store.environment }

    /// Where the commands ask and tell the user.
    internal var interaction: any UserInteraction { kernel.interaction }
    /// The kernel's file systems.
    internal var fileSystems: FileSystemRegistry { kernel.fileSystems }
    /// The settings of the program.
    internal var settings: any SettingsStore { kernel.settings }
    /// The panel the commands work on.
    internal var source: any PanelHandle { kernel.panels.source }
    /// The other panel, where packing and unpacking go by default.
    internal var target: any PanelHandle { kernel.panels.target }

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

    /// The commands of `kernel` over the archives of `store`; `currentEvent` tells which key is
    /// being handled.
    internal init(
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

    /// The first problems of a longer list, for a message box.
    nonisolated internal static func summary(of problems: [String]) -> String {
        problems.prefix(12).joined(separator: "\n") + (problems.count > 12 ? "\n… and \(problems.count - 12) more" : "")
    }

    /// Copies what `reader` reads into a new file at `local`.
    ///
    /// `cancellation` interrupts a read that hangs. On the job's thread.
    nonisolated private static func copy(
        _ reader: any FileReader,
        to local: URL,
        cancellation: CancellationFlag
    ) throws {
        let tie = cancellation.interrupting(reader)
        defer {
            withExtendedLifetime(tie) {
                // Listened to until the copy is over.
            }
        }
        let output = try OutputFile(creating: local, mode: 0o600)
        while let block = try reader.read(upToCount: 1 << 20) { try output.write(block) }
        try output.close(durably: false)
    }

    /// Copies the settings for the working threads; called on the main thread.
    internal func refreshOptions() {
        environment.options = ArchiveSettings.options(from: settings)
    }

    /// Re-reads the panels after archives were written: the folders given, and every panel
    /// that is inside an archive.
    internal func refreshPanels(_ directories: [URL], focus: URL?) {
        let inArchives = kernel.panels.all.map(\.model.directory).filter(ArchiveURL.isArchiveURL)
        kernel.panels.refresh(directories + inArchives, focus: focus)
    }

    /// The location that shows the archive `file` as a folder; `isKnownZip` says it is a ZIP
    /// when its name does not (false: go by the name).
    internal func archiveRoot(for file: URL, isKnownZip: Bool) -> URL {
        ArchiveURL.make(
            scheme: ArchiveFileSystem.scheme(forArchive: file, fileSystems: fileSystems, isKnownZip: isKnownZip),
            archive: file,
            innerPath: ""
        )
    }

    /// The opener for Enter: archives are entered like folders.
    internal func open(_ file: FileItem, in panel: any PanelHandle) -> Bool {
        let options = environment.options
        guard !file.isDirectory else {
            return false
        }
        let known = options.opensAsFolders && options.extensions.contains(file.ext.lowercased())
        guard known || (options.entersAnyFile && isForcedOpen) else {
            return false
        }
        panel.show(archiveRoot(for: file.url, isKnownZip: false))
        return true
    }

    /// Enter on a file inside an archive shows what the archive knows about it
    /// (spec 08 › Enter on a file inside an archive).
    internal func showMember(_ file: FileItem, in _: any PanelHandle) -> Bool {
        guard let location = ArchiveURL.location(of: file.url), !file.isDirectory else {
            return false
        }
        kernel.jobs.run(
            title: "Reading:",
            work: { [store] monitor in
                (try? store.archive(at: location.archive, cancellation: monitor.cancellation))?
                    .entry(location.innerPath)
            },
            completion: { [self] entry in
                if let entry { showDetails(of: entry, at: file) }
            }
        )
        return true
    }

    /// The message about one member, with View and "Unpack and Open".
    private func showDetails(of entry: ArchiveEntry, at file: FileItem) {
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
        let answer = interaction.choose(entry.name, detail: detail, buttons: buttons, style: .information)
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

    /// Unpacks one member into the temporary folder and hands it to its application.
    private func unpackAndOpen(_ file: FileItem) {
        kernel.jobs.run(
            title: "Unpacking:",
            work: { [fileSystems, store, scratch = environment.scratch] monitor -> Result<URL, any Error> in
                Result {
                    let folder = try scratch.newFile("open")
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let local = folder.appendingPathComponent(file.name, isDirectory: false)
                    // Cancel ends the opening of the member (which may lie behind a long stretch
                    // of decompression), a read that hangs, and the reads after it.
                    let reader = try fileSystems.provider(for: file.url)
                        .read(file.url, cancellation: monitor.cancellation)
                    defer { reader.close() }
                    try Self.copy(reader, to: local, cancellation: monitor.cancellation)
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
                    interaction.report(error, title: "\(file.name) cannot be unpacked!")
                }
            }
        )
    }

    /// Enters the file under the cursor as an archive, whatever it is called.
    ///
    /// The first bytes are read in the background to see whether it is a ZIP, which can be changed.
    internal func openAsArchive() {
        let panel = source
        guard let file = panel.model.cursorFile else {
            return
        }
        kernel.jobs.run(
            title: "Opening:",
            work: { [fileSystems] monitor -> Bool in
                guard
                    let reader = try? fileSystems.provider(for: file.url)
                        .read(file.url, cancellation: monitor.cancellation)
                else { return false }
                defer { reader.close() }
                let tie = monitor.cancellation.interrupting(reader)
                defer {
                    withExtendedLifetime(tie) {
                        // Listened to until the first bytes are read.
                    }
                }
                let head = try? reader.read(upToCount: 4)
                return head.map { [UInt8]($0.prefix(2)) == [0x50, 0x4B] } ?? false
            },
            completion: { [self] isZip in
                panel.show(archiveRoot(for: file.url, isKnownZip: isZip))
            }
        )
    }

    deinit {
        // Nothing to release.
    }
}
