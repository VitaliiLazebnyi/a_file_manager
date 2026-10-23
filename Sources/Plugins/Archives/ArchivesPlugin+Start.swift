import AFMContracts
public import AFMKernel
import Foundation

/// What the plugin registers with the kernel when it starts.
extension ArchivesPlugin {
    /// Gives the environment what it needs of the kernel: the file systems, the questions for
    /// passwords, the messages about failed writes and the refresh of the panels.
    private static func connect(_ environment: ArchiveEnvironment, to owner: Kernel) {
        unowned let kernel = owner
        environment.fileSystems = { [weak kernel] in kernel?.fileSystems }
        environment.recoveryFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(kernel.productName, isDirectory: true)
            .appendingPathComponent(
                "Unsaved archive changes",
                isDirectory: true
            )
        environment.askPassword = { [weak kernel] archive, retry in
            // `@Sendable`, so that it may be sent from this thread to the main thread.
            kernel?
                .askUser { @Sendable interaction in
                    let answer = interaction.form(
                        retry ? "Wrong password" : "Password",
                        detail: "\(archive) is encrypted.",
                        fields: [.password("password", "Password:")],
                        buttons: ["OK"]
                    )
                    return answer.flatMap { $0.text("password").isEmpty ? nil : $0.text("password") }
                }
        }
        // Not waited for: the thread that writes archives goes on (and is not kept from the
        // shared pool) while the message is on the screen.
        environment.reportFailure = { [weak kernel] error, archive in
            let show: @MainActor @Sendable () -> Void = { [weak kernel] in
                kernel?.interaction.report(error, title: "The changes to \(archive) could not be written!")
            }
            if Thread.isMainThread { MainActor.assumeIsolated(show) } else { DispatchQueue.main.async(execute: show) }
        }
        // A copy job that reads a thousand encrypted members asks for the password once.
        environment.passwordRefusalMemory = 5
        // After a delayed write the archive file has a new size and date: the panels that
        // show its folder follow.
        environment.contentsChanged = { [weak kernel] archive in
            DispatchQueue.main.async { [weak kernel] in kernel?.panels.refresh([archive.deletingLastPathComponent()]) }
        }
    }

    /// Registers Pack, Move to Archive, Unpack, Test and Open as Archive.
    private static func registerCommands(of actions: ArchiveCommands, in owner: Kernel) {
        unowned let kernel = owner
        let commands = kernel.commands
        let model = { kernel.panels.source.model }
        let hasOperands = { model().hasOperands }
        let isInsideArchive = { ArchiveURL.location(of: model().directory) != nil }
        commands.register(Command(.packFiles, "Pack…", [.f(5, .option)]), enabled: hasOperands) {
            actions.pack(move: false)
        }
        commands.register(
            Command(.moveToArchive, "Move to Archive…", [.f(5, [.option, .shift])]),
            enabled: hasOperands
        ) { actions.pack(move: true) }
        commands.register(
            Command(.unpackFiles, "Unpack Specific Files…", [.f(9, .option)]),
            enabled: { hasOperands() || isInsideArchive() },
            actions.unpack
        )
        commands.register(
            Command(.testArchive, "Test Archive(s)", [.f(9, [.option, .shift])]),
            enabled: { hasOperands() || isInsideArchive() },
            actions.test
        )
        commands.register(
            Command(.openAsArchive, "Open as Archive"),
            enabled: { model().cursorFile != nil },
            actions.openAsArchive
        )
    }

    /// Puts the commands into the Files menu, the context menu of archives and the toolbar.
    private static func addMenusAndButtons(to kernel: Kernel) {
        kernel.menus.add([.packFiles, .moveToArchive, .unpackFiles, .testArchive, .openAsArchive], to: .filesArchives)
        kernel.menus.addToContextMenu([.packFiles, .unpackFiles, .testArchive], in: .archives, onItemOnly: true)
        kernel.toolbar.add(
            .packFiles,
            symbol: "archivebox",
            group: 30,
            hint: "Pack the selected files into an archive (ZIP, TAR and others)."
        )
        kernel.toolbar.add(.unpackFiles, symbol: "shippingbox", group: 30, hint: "Unpack the selected archives.")
        kernel.toolbar.setSymbol("checkmark.seal", for: .testArchive)
        kernel.toolbar.setSymbol("arrow.down.right.and.arrow.up.left", for: .openAsArchive)
    }

    /// The Packer page of the configuration; `onChange` is told when one of its settings changed.
    private static func packerPage(onChange: @escaping @MainActor @Sendable () -> Void) -> PreferencePage {
        PreferencePage(title: "Packer", preferences: openingPreferences() + packingPreferences(), onChange: onChange)
    }

    /// The settings of the Packer page that say which files open as archives, and how packing starts.
    private static func openingPreferences() -> [Preference] {
        [
            Preference(
                ArchiveSettings.opensAsFolders,
                "Treat archives like directories (Enter opens them)",
                .flag(default: true)
            ),
            Preference(
                ArchiveSettings.extensions,
                "Files that open as archives",
                .text(default: ArchiveSettings.defaultExtensions)
            ),
            Preference(ArchiveSettings.entersAnyFile, "Ctrl+PgDn enters any file as an archive", .flag(default: true)),
            Preference(
                ArchiveSettings.format,
                "Default packer",
                .choice(ArchiveFormat.writable.map(\.title), default: 0)
            ),
            Preference(ArchiveSettings.level, "Compression rate", .choice(ArchiveSettings.levels, default: 6))
        ]
    }

    /// The settings of the Packer page for packing and unpacking.
    private static func packingPreferences() -> [Preference] {
        [
            Preference(ArchiveSettings.storesPaths, "Also pack path names (only recursed)", .flag(default: true)),
            Preference(ArchiveSettings.recurses, "Recursively pack subdirectories", .flag(default: true)),
            Preference(ArchiveSettings.verifies, "Test ZIP archives after packing", .flag(default: true)),
            Preference(ArchiveSettings.datesByNewest, "Set archive date to newest file date", .flag(default: false)),
            Preference(ArchiveSettings.unpackPaths, "Unpack path names if stored with files", .flag(default: true)),
            Preference(
                ArchiveSettings.unpackSeparate,
                "Unpack each archive to a separate subdir",
                .flag(default: false)
            ),
            Preference(
                ArchiveSettings.unpackOverwrite,
                "Overwrite existing files when unpacking",
                .flag(default: false)
            )
        ]
    }

    /// Registers the file systems, the openers, the commands with their menus and buttons, and
    /// the Packer page of the configuration; called once, on the main thread.
    public func start(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        let actions = ArchiveCommands(
            kernel: kernel,
            store: store,
            openFile: openFile,
            currentEvent: ArchiveCommands.handledEvent
        )
        actions.refreshOptions()
        Self.connect(environment, to: kernel)
        // What a crash left in the temporary folder, and next to archives, is cleared away.
        BlockingCalls.run { ScratchFolder.sweepLeftovers(in: FileManager.default.temporaryDirectory) }

        for scheme in ArchiveURL.schemes {
            kernel.fileSystems.register(ArchiveFileSystem(scheme: scheme, store: store))
        }
        // Changes to a ZIP are written into its file after a delay. Whoever is about to
        // read, copy, move or delete that file (or the folder it lies in) asks for them first.
        kernel.fileSystems.addFlusher { [store] url, cancellation in
            try store.bringUpToDate(url, cancellation: cancellation)
        }
        kernel.fileSystems.addVolumeCloser { [store] volume, _ in store.release(on: volume) }
        // Ahead of the general opener, which would hand an archive to its application.
        kernel.openers.add(priority: 10, actions.open)
        kernel.openers.add(priority: 5, actions.showMember)

        Self.registerCommands(of: actions, in: kernel)
        Self.addMenusAndButtons(to: kernel)
        kernel.preferences.add(Self.packerPage { actions.refreshOptions() })
    }
}
