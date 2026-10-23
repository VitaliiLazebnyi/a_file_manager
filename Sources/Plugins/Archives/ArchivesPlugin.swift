import AFMContracts
public import AFMKernel
public import Foundation

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
    /// What the stop's background thread hands back.
    ///
    /// All state is guarded by `lock`.
    private final class StopState: @unchecked Sendable {
        private let lock = NSLock()
        private var result: [(error: any Error, name: String)] = []
        private var finished = false

        /// True once the thread has handed back its reports.
        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }

        /// What the thread handed back; empty until it is finished.
        var reports: [(error: any Error, name: String)] {
            lock.lock()
            defer { lock.unlock() }
            return result
        }

        /// Hands back the reports and marks the state finished.
        func finish(_ reports: [(error: any Error, name: String)]) {
            lock.lock()
            (result, finished) = (reports, true)
            lock.unlock()
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The plugin's name, as the kernel lists it.
    public let name = "Archives"
    /// The settings, limits and hooks the archives share with their working threads.
    ///
    /// Not private: the tests set limits and hooks.
    internal let environment = ArchiveEnvironment()
    /// The archives that are open, shared by the two file systems and the commands.
    internal let store: ArchiveStore
    /// What "Unpack and Open" hands the unpacked member to; nil opens nothing.
    internal let openFile: (@MainActor (URL) -> Bool)?

    /// True when changes made inside archives have not been written into their files yet.
    ///
    /// Answers from memory; any thread.
    public var hasPendingChanges: Bool { store.hasPendingChanges }

    /// `flushDelay`: how long after the last change to a ZIP the changes are written into the
    /// archive file; nil leaves that to `flushPendingChanges()` (tests). `launchesApplications`
    /// is off in tests, so "Unpack and Open" starts nothing.
    public convenience init(flushDelay: TimeInterval? = 0.5, launchesApplications: Bool = true) {
        self.init(flushDelay: flushDelay, openFile: launchesApplications ? ArchiveCommands.openInApplication : nil)
    }

    /// The same with what "Unpack and Open" hands its file to in place of the system's applications.
    internal init(flushDelay: TimeInterval?, openFile: (@MainActor (URL) -> Bool)?) {
        environment.flushDelay = flushDelay
        store = ArchiveStore(environment: environment)
        self.openFile = openFile
    }

    /// Waits until the state is finished or the time is up; true when it is finished.
    ///
    /// The main thread's run loop keeps turning meanwhile, so that what other threads send to the
    /// main thread (a question to the user) is done and does not wait for this wait.
    private static func wait(until deadline: Date, for state: StopState) -> Bool {
        // A run loop with nothing to watch returns at once: this port, which nothing sends to,
        // gives it something, so the wait below does not spin.
        let keeper = NSMachPort()
        RunLoop.current.add(keeper, forMode: .default)
        defer { RunLoop.current.remove(keeper, forMode: .default) }
        while !state.isFinished, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        return state.isFinished
    }

    /// The messages for the archives whose changes could not be written at the stop.
    ///
    /// Out of time, the new members are kept as they lie; otherwise they are saved in an archive
    /// of their own, and the message says where. Runs on the stop's background thread.
    nonisolated private static func rescueReports(
        for failures: [ArchiveStore.WriteFailure],
        store: ArchiveStore,
        environment: ArchiveEnvironment,
        deadline: Date
    ) -> [(error: any Error, name: String)] {
        let late = environment.quitting.isCancelled
        let rescued = store.rescueAll(quickly: late, before: late ? Date(timeIntervalSinceNow: 2) : deadline)
        // By archive, not by name: two may be called the same. (The table holds each archive once.)
        let outcomes = Dictionary(uniqueKeysWithValues: rescued.map { (ObjectIdentifier($0.archive), $0.outcome) })
        return failures.map { failure in
            var text = failure.error.localizedDescription
            switch outcomes[ObjectIdentifier(failure.archive)] {
            case .saved(let url):
                text += "\n\nThe files that were added are in \(url.path)."

            case .kept(let folder):
                text +=
                    "\n\nThe files that were added could not be saved elsewhere. "
                    + "Their compressed data is in \(folder.path) (index.txt there says which file is which)."

            case .nothingToSave, nil:
                break
            }
            return (ArchiveError.unsaved(text), failure.name)
        }
    }

    /// The kernel's hook for work before quitting: the changes that still wait are written
    /// into their archives on a background thread, while every service is still there (a
    /// server an archive lies on is still connected) and the shell shows that the program is
    /// busy.
    ///
    /// `completion` is called when all is written, or when the writes ended because `cancellation`
    /// was set: the user did not want to wait. Nothing is lost by that: what was not written still
    /// waits, and `stop()`, which then no longer tries to write it, keeps it on the disk and says
    /// where.
    @preconcurrency
    public func prepareToQuit(cancellation: CancellationFlag, completion: @escaping @Sendable () -> Void) {
        guard store.hasPendingChanges else {
            completion()
            return
        }
        Thread.detachNewThread { [store, environment] in
            store.flushAll(cancellation: cancellation)
            // Not waiting is not waiting: the stop does not start the writes over.
            if cancellation.isCancelled { environment.quitting.cancel() }
            completion()
        }
    }

    /// Writes what is still waiting to go into archives, then removes the temporary files.
    ///
    /// With a shell that calls `prepareToQuit` there is usually nothing left to write here; this is
    /// what holds when there is. Changes that cannot be written are not dropped with them: the user
    /// is told, and the new members are saved in an archive of their own (see
    /// `OpenArchive.rescue()`).
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
        // From here on the delayed writes start nothing; this is the one write.
        environment.isStopping = true
        guard store.hasPendingChanges else {
            store.close()
            return
        }

        let state = StopState()
        let deadline = Date(timeIntervalSinceNow: environment.quitTimeout)
        Thread.detachNewThread { [store, environment] in
            let failures = store.flushAll(cancellation: environment.quitting)
            state.finish(
                failures.isEmpty
                    ? []
                    : Self.rescueReports(for: failures, store: store, environment: environment, deadline: deadline)
            )
        }
        if !Self.wait(until: deadline, for: state) {
            // Long enough: the writes end where they are, and what they hold is kept.
            environment.quitting.cancel()
            _ = Self.wait(
                until: Date(timeIntervalSinceNow: min(15, max(1, environment.quitTimeout))),
                for: state
            )
        }
        guard state.isFinished else {
            // Something waits for a disk or a server that does not answer. Its thread is
            // left alone and so is every temporary file: nothing is deleted under it.
            environment.scratch.keep()
            let text =
                "Changes to archives were still being written when the program had to quit. "
                + "What was added and not yet written is kept in \(environment.scratch.url.path)."
            environment.reportFailure(ArchiveError.unsaved(text), "archives")
            return
        }
        for report in state.reports { environment.reportFailure(report.error, report.name) }
        store.close()
    }

    /// Writes the changes made inside ZIP archives into the archive files on a background
    /// thread and calls `completion` on the main thread with what failed, one line per
    /// archive.
    ///
    /// For a shell that wants to show "Saving archives…" before it lets the program quit;
    /// `cancellation` ends the writes early, and nothing is lost by that: what was not written
    /// keeps waiting (and `stop()` deals with it).
    @preconcurrency
    public func writePendingChanges(
        cancellation: CancellationFlag,
        completion: @escaping @MainActor @Sendable ([String]) -> Void
    ) {
        Thread.detachNewThread { [store] in
            let failed = store.flushAll(cancellation: cancellation)
                .map { failure in
                    "\(failure.name): \(failure.error.localizedDescription)"
                }
            DispatchQueue.main.async { completion(failed) }
        }
    }

    /// Writes the changes made inside ZIP archives into the archive files now, instead of
    /// shortly after the last change.
    ///
    /// Blocks while it writes (not for the main thread of the running program; tests call it);
    /// returns what failed, one line per archive.
    @discardableResult
    public func flushPendingChanges() -> [String] {
        store.flushAll(cancellation: nil).map { "\($0.name): \($0.error.localizedDescription)" }
    }

    /// The location that shows the archive file at `file` as a folder, as Enter would open it.
    public func location(ofArchive file: URL, in kernel: Kernel) -> URL {
        ArchiveURL.make(
            scheme: ArchiveFileSystem.scheme(forArchive: file, fileSystems: kernel.fileSystems, isKnownZip: false),
            archive: file,
            innerPath: ""
        )
    }

    deinit {
        // Nothing to release: `stop()` closes the archives.
    }
}
