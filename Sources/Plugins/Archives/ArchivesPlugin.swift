import AFMContracts
import AFMKernel
import Foundation

/// Archives as folders; pack, unpack and test (spec 08).
///
/// The plugin provides two file systems (`zip:` for archives that can be changed, `archive:`
/// for those that are only read), an opener that enters archives on Enter, and the commands
/// Pack, Unpack and Test with their menu entries, buttons and the Packer page of the
/// configuration. ZIP, TAR, GZIP and XZ are read and written by the plugin itself (with the
/// system's zlib and Compression framework); BZIP2 goes through `/usr/bin/bzip2`, and
/// everything else libarchive knows (7z, rar, iso, cab, cpio, xar, …) is read through
/// `/usr/bin/bsdtar`, both run as child processes without a shell.
public final class ArchivesPlugin: Plugin {
    public let name = "Archives"
    // (Not private: the tests set limits and hooks.)
    let environment = ArchiveEnvironment()
    let store: ArchiveStore
    private let launchesApplications: Bool

    /// `flushDelay`: how long after the last change to a ZIP the changes are written into the
    /// archive file; nil leaves that to `flushPendingChanges()` (tests). `launchesApplications`
    /// is off in tests, so "Unpack and Open" starts nothing.
    public init(flushDelay: TimeInterval? = 0.5, launchesApplications: Bool = true) {
        environment.flushDelay = flushDelay
        store = ArchiveStore(environment: environment)
        self.launchesApplications = launchesApplications
    }

    public func start(in kernel: Kernel) {
        let (store, environment) = (self.store, self.environment)
        let actions = ArchiveCommands(kernel: kernel, store: store, launchesApplications: launchesApplications)
        actions.refreshOptions()

        environment.fileSystems = { [weak kernel] in kernel?.fileSystems }
        environment.recoveryFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(kernel.productName, isDirectory: true).appendingPathComponent(
                "Unsaved archive changes", isDirectory: true)
        environment.askPassword = { [weak kernel] archive, retry in
            kernel?.askUser { ui in
                let answer = ui.form(
                    retry ? "Wrong password" : "Password", detail: "\(archive) is encrypted.",
                    fields: [.password("password", "Password:")], buttons: ["OK"])
                return answer.flatMap { $0.text("password").isEmpty ? nil : $0.text("password") }
            }
        }
        // Not waited for: the thread that writes archives goes on (and is not kept from the
        // shared pool) while the message is on the screen.
        environment.reportFailure = { [weak kernel] error, archive in
            let show: () -> Void = {
                kernel?.ui.report(error, title: "The changes to \(archive) could not be written!")
            }
            if Thread.isMainThread { show() } else { DispatchQueue.main.async(execute: show) }
        }
        // A copy job that reads a thousand encrypted members asks for the password once.
        environment.passwordRefusalMemory = 5
        // What a crash left in the temporary folder, and next to archives, is cleared away.
        BlockingCalls.run { ScratchFolder.sweepLeftovers() }
        // After a delayed write the archive file has a new size and date: the panels that
        // show its folder follow.
        environment.contentsChanged = { [weak kernel] archive in
            DispatchQueue.main.async { kernel?.panels.refresh([archive.deletingLastPathComponent()]) }
        }

        for scheme in ArchiveURL.schemes {
            kernel.fileSystems.register(ArchiveFileSystem(scheme: scheme, store: store))
        }
        // Changes to a ZIP are written into its file after a delay. Whoever is about to
        // read, copy, move or delete that file (or the folder it lies in) asks for them first.
        kernel.fileSystems.addFlusher { url, cancellation in try store.bringUpToDate(url, cancellation: cancellation) }
        kernel.fileSystems.addVolumeCloser { volume, _ in store.release(on: volume) }
        // Ahead of the general opener, which would hand an archive to its application.
        kernel.openers.add(priority: 10, actions.open)
        kernel.openers.add(priority: 5, actions.showMember)

        let commands = kernel.commands
        let model = { kernel.panels.source.model }
        let hasOperands = { model().hasOperands }
        let isInsideArchive = { ArchiveURL.location(of: model().directory) != nil }
        commands.register(Command(.packFiles, "Pack…", [.f(5, .option)]), enabled: hasOperands) {
            actions.pack(move: false)
        }
        commands.register(
            Command(.moveToArchive, "Move to Archive…", [.f(5, [.option, .shift])]), enabled: hasOperands
        ) { actions.pack(move: true) }
        commands.register(
            Command(.unpackFiles, "Unpack Specific Files…", [.f(9, .option)]),
            enabled: { hasOperands() || isInsideArchive() }, actions.unpack)
        commands.register(
            Command(.testArchive, "Test Archive(s)", [.f(9, [.option, .shift])]),
            enabled: { hasOperands() || isInsideArchive() }, actions.test)
        commands.register(
            Command(.openAsArchive, "Open as Archive"), enabled: { model().cursorFile != nil }, actions.openAsArchive)

        kernel.menus.add([.packFiles, .moveToArchive, .unpackFiles, .testArchive, .openAsArchive], to: .filesArchives)
        kernel.menus.addToContextMenu([.packFiles, .unpackFiles, .testArchive], in: .archives, onItemOnly: true)
        kernel.toolbar.add(
            .packFiles, symbol: "archivebox", group: 30,
            hint: "Pack the selected files into an archive (ZIP, TAR and others).")
        kernel.toolbar.add(.unpackFiles, symbol: "shippingbox", group: 30, hint: "Unpack the selected archives.")
        kernel.toolbar.setSymbol("checkmark.seal", for: .testArchive)
        kernel.toolbar.setSymbol("arrow.down.right.and.arrow.up.left", for: .openAsArchive)

        kernel.preferences.add(
            PreferencePage(
                title: "Packer",
                preferences: [
                    Preference(
                        ArchiveSettings.opensAsFolders, "Treat archives like directories (Enter opens them)",
                        .flag(default: true)),
                    Preference(
                        ArchiveSettings.extensions, "Files that open as archives",
                        .text(default: ArchiveSettings.defaultExtensions)),
                    Preference(
                        ArchiveSettings.entersAnyFile, "Ctrl+PgDn enters any file as an archive", .flag(default: true)
                    ),
                    Preference(
                        ArchiveSettings.format, "Default packer",
                        .choice(ArchiveFormat.writable.map(\.title), default: 0)),
                    Preference(
                        ArchiveSettings.level, "Compression rate", .choice(ArchiveSettings.levels, default: 6)),
                    Preference(
                        ArchiveSettings.storesPaths, "Also pack path names (only recursed)", .flag(default: true)),
                    Preference(ArchiveSettings.recurses, "Recursively pack subdirectories", .flag(default: true)),
                    Preference(ArchiveSettings.verifies, "Test ZIP archives after packing", .flag(default: true)),
                    Preference(
                        ArchiveSettings.datesByNewest, "Set archive date to newest file date", .flag(default: false)),
                    Preference(
                        ArchiveSettings.unpackPaths, "Unpack path names if stored with files", .flag(default: true)),
                    Preference(
                        ArchiveSettings.unpackSeparate, "Unpack each archive to a separate subdir",
                        .flag(default: false)),
                    Preference(
                        ArchiveSettings.unpackOverwrite, "Overwrite existing files when unpacking",
                        .flag(default: false))
                ], onChange: actions.refreshOptions))
    }

    /// The kernel's hook for work before quitting: the changes that still wait are written
    /// into their archives on a background thread, while every service is still there (a
    /// server an archive lies on is still connected) and the shell shows that the program is
    /// busy. `completion` is called when all is written, or when the writes ended because
    /// `cancellation` was set: the user did not want to wait. Nothing is lost by that: what
    /// was not written still waits, and `stop()`, which then no longer tries to write it,
    /// keeps it on the disk and says where.
    public func prepareToQuit(cancellation: CancellationFlag, completion: @escaping () -> Void) {
        let (store, environment) = (self.store, self.environment)
        guard store.hasPendingChanges else {
            completion()
            return
        }
        Thread.detachNewThread {
            store.flushAll(cancellation: cancellation)
            // Not waiting is not waiting: the stop does not start the writes over.
            if cancellation.isCancelled { environment.quitting.cancel() }
            completion()
        }
    }

    /// Writes what is still waiting to go into archives, then removes the temporary files.
    /// With a shell that calls `prepareToQuit` there is usually nothing left to write here;
    /// this is what holds when there is. Changes that cannot be written are not dropped with them: the user is told, and the
    /// new members are saved in an archive of their own (see `OpenArchive.rescue()`).
    ///
    /// **Threading.** Called on the main thread when the program quits. The writing itself
    /// runs on a background thread; this thread waits for it while it keeps the main run loop
    /// turning, so a write that needs the user (a server asking for a password puts its
    /// question on the main thread) gets its answer instead of waiting for a thread that
    /// waits for it. The wait is bounded (`ArchiveEnvironment.quitTimeout`): after it the
    /// writes are told to end, and what they could not write is kept on the disk and
    /// reported. If even that does not end them (a server that never answers), the program
    /// quits all the same, and nothing of the temporary data is removed.
    public func stop() {
        let (store, environment) = (self.store, self.environment)
        // From here on the delayed writes start nothing; this is the one write.
        environment.isStopping = true
        guard store.hasPendingChanges else {
            store.close()
            return
        }

        let state = StopState()
        let deadline = Date(timeIntervalSinceNow: environment.quitTimeout)
        Thread.detachNewThread {
            let failures = store.flushAll(cancellation: environment.quitting)
            var reports: [(error: any Error, name: String)] = []
            if !failures.isEmpty {
                // Out of time, the members are kept as they lie; otherwise they are saved in
                // an archive of their own. By archive, not by name: two may be called the same.
                let late = environment.quitting.isCancelled
                let rescued = store.rescueAll(quickly: late, before: late ? Date(timeIntervalSinceNow: 2) : deadline)
                let outcomes = Dictionary(
                    rescued.map { (ObjectIdentifier($0.archive), $0.outcome) }, uniquingKeysWith: { first, _ in first }
                )
                for failure in failures {
                    var text = failure.error.localizedDescription
                    switch outcomes[ObjectIdentifier(failure.archive)] {
                    case .saved(let url): text += "\n\nThe files that were added are in \(url.path)."

                    case .kept(let folder):
                        text +=
                            "\n\nThe files that were added could not be saved elsewhere. Their compressed data is in \(folder.path)"
                            + " (index.txt there says which file is which)."

                    case .nothingToSave, nil: break
                    }
                    reports.append((ArchiveError.unsaved(text), failure.name))
                }
            }
            state.finish(reports)
        }
        if !Self.wait(until: deadline, for: state) {
            // Long enough: the writes end where they are, and what they hold is kept.
            environment.quitting.cancel()
            _ = Self.wait(
                until: Date(timeIntervalSinceNow: min(15, max(1, environment.quitTimeout))), for: state)
        }
        guard let reports = state.reports else {
            // Something waits for a disk or a server that does not answer. Its thread is
            // left alone and so is every temporary file: nothing is deleted under it.
            environment.scratch.keep()
            let text =
                "Changes to archives were still being written when the program had to quit. "
                + "What was added and not yet written is kept in \(environment.scratch.url.path)."
            environment.reportFailure(ArchiveError.unsaved(text), "archives")
            return
        }
        for report in reports { environment.reportFailure(report.error, report.name) }
        store.close()
    }

    /// What the stop's background thread hands back.
    private final class StopState {
        private let lock = NSLock()
        private var result: [(error: any Error, name: String)]?

        var reports: [(error: any Error, name: String)]? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }

        func finish(_ reports: [(error: any Error, name: String)]) {
            lock.lock()
            result = reports
            lock.unlock()
        }
    }

    /// Waits until the state is finished or the time is up; true when it is finished. On the
    /// main thread the run loop keeps turning meanwhile, so that what other threads send to
    /// the main thread (a question to the user) is done and does not wait for this wait.
    private static func wait(until deadline: Date, for state: StopState) -> Bool {
        while state.reports == nil, Date() < deadline {
            if Thread.isMainThread {
                // A run loop with nothing to watch returns at once; then this must not spin.
                if !RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02)) { usleep(5_000) }
            } else {
                usleep(5_000)
            }
        }
        return state.reports != nil
    }

    /// True when changes made inside archives have not been written into their files yet.
    /// Answers from memory; any thread.
    public var hasPendingChanges: Bool { store.hasPendingChanges }

    /// Writes the changes made inside ZIP archives into the archive files on a background
    /// thread and calls `completion` on the main thread with what failed, one line per
    /// archive. For a shell that wants to show "Saving archives…" before it lets the program
    /// quit; `cancellation` ends the writes early, and nothing is lost by that: what was not
    /// written keeps waiting (and `stop()` deals with it).
    public func writePendingChanges(cancellation: CancellationFlag, completion: @escaping ([String]) -> Void) {
        let store = self.store
        Thread.detachNewThread {
            let failed = store.flushAll(cancellation: cancellation).map {
                "\($0.name): \($0.error.localizedDescription)"
            }
            DispatchQueue.main.async { completion(failed) }
        }
    }

    /// Writes the changes made inside ZIP archives into the archive files now, instead of
    /// shortly after the last change. Blocks while it writes (not for the main thread of the
    /// running program; tests call it); returns what failed, one line per archive.
    @discardableResult
    public func flushPendingChanges() -> [String] {
        store.flushAll().map { "\($0.name): \($0.error.localizedDescription)" }
    }

    /// The location that shows the archive file at `file` as a folder, as Enter would open it.
    public func location(ofArchive file: URL, in kernel: Kernel) -> URL {
        ArchiveURL.make(
            scheme: ArchiveFileSystem.scheme(forArchive: file, fileSystems: kernel.fileSystems), archive: file)
    }
}
