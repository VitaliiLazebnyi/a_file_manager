import AFMContracts
import AFMKernel
import Foundation

/// The behaviour behind the commands.
///
/// It only talks to the kernel: panels, questions, jobs and file systems.
///
/// **Threading.** Commands start on the main thread and only prepare there: they read the
/// panel's state and the settings and ask the user. Everything that touches a file system runs
/// inside a job, on the job's thread; the job's completion returns to the main thread to
/// refresh the panels. The operation log writes on its own queue.
internal final class FileOperations: FileTransferService {
    /// How long the end of the program waits for the log's last lines.
    internal static let logFlushTimeout: TimeInterval = 2

    /// Unowned: the kernel owns the plugin, and through it this.
    internal unowned let kernel: Kernel
    /// The log as last configured; made again when the configuration page changed something.
    private var log: OperationLog? {
        didSet {
            logLock.lock()
            sharedLog = log
            logLock.unlock()
        }
    }
    /// `log` for the thread that ejects a volume, which may be the one the log is written to.
    private let logLock = NSLock()
    /// Guarded by `logLock`.
    nonisolated(unsafe) private var sharedLog: OperationLog?

    /// The text of the clipboard, for `[X]`; read on a job's thread, only when a name asks for it (another program
    /// may hand its text over slowly).
    internal let clipboard: @Sendable () -> String?

    /// The panel the commands work on.
    internal var source: any PanelHandle { kernel.panels.source }
    /// The other panel, where copies and moves go.
    internal var target: any PanelHandle { kernel.panels.target }
    /// The dialogs; main thread.
    internal var interaction: any UserInteraction { kernel.interaction }
    /// The file systems the operations work on.
    internal var fileSystems: FileSystemRegistry { kernel.fileSystems }

    /// The operations of `kernel`, reading the clipboard through `clipboard`.
    internal init(_ kernel: Kernel, clipboard: @escaping @Sendable () -> String?) {
        self.kernel = kernel
        self.clipboard = clipboard
    }

    /// The panel's names of the items a job processed.
    ///
    /// In a branch or list view a name is a path, not the last component of the item's location, so
    /// the items are matched by URL.
    internal static func names(of processed: [URL], among items: [FileItem]) -> [String] {
        var wanted = Set(processed.map(\.locationKey))
        guard !wanted.isEmpty else {
            return []
        }
        var names: [String] = []
        for item in items where wanted.remove(item.url.locationKey) != nil { names.append(item.name) }
        return names
    }

    /// Job thread: a log written to `volume` writes what it has and closes its file, so the
    /// volume can be ejected.
    ///
    /// The next line opens it again.
    nonisolated internal func closeLog(on volume: URL) {
        logLock.lock()
        let current = sharedLog
        logLock.unlock()
        guard let current else {
            return
        }
        let file = current.configuration.file
        if file.isSameLocation(as: volume) || file.isInside(volume) { current.flush() }
    }

    /// Writes what the log still holds, waiting at most `logFlushTimeout`; for the end of the program.
    internal func flushLog() {
        log?.flush(timeout: Self.logFlushTimeout)
    }

    /// Writes what the log still holds, off the calling thread; `completion` is called once,
    /// on some thread, when it is written or `cancellation` was set.
    internal func flushLog(cancellation: CancellationFlag, completion: @escaping @Sendable () -> Void) {
        guard let log else {
            completion()
            return
        }
        log.flush(cancellation: cancellation, completion: completion)
    }

    /// Where a job's records go: nil while the log is switched off.
    internal func recorder() -> (@Sendable (OperationRecord) -> Void)? {
        let configuration = OperationSettings.logConfiguration(from: kernel.settings)
        guard configuration.isEnabled else {
            return nil
        }
        let current: OperationLog
        if let log, log.configuration == configuration {
            current = log
        } else {
            current = OperationLog(configuration)
            log = current
        }
        return { record in current.write(record) }
    }

    /// Which records the log is going to keep, so that a job makes no others.
    private func recordFilter() -> (@Sendable (OperationRecord.Verb, OperationRecord.Status) -> Bool)? {
        let configuration = OperationSettings.logConfiguration(from: kernel.settings)
        guard configuration.isEnabled else {
            return nil
        }
        return { verb, status in configuration.wants(verb, status) }
    }

    /// Runs `makeJob` and the job it returns on the job thread, with the progress window; the
    /// job's questions are asked through the kernel. `makeJob` may refuse with a message.
    /// `summary` turns the job's result into what the completion needs while still on the job
    /// thread (the names to deselect, the folders to re-read: work that grows with the
    /// selection), so that the completion on the main thread only applies it.
    internal func run<Summary: Sendable>(
        title: String,
        makeJob: @escaping @Sendable (CancellationFlag) -> Result<FileJob, JobRefusal>,
        summary: @escaping @Sendable (JobResult) -> Summary,
        completion: @escaping @MainActor (JobResult, Summary) -> Void
    ) {
        let record = recorder()
        let wantsRecord = recordFilter()
        let operationLog = log
        kernel.jobs.run(
            title: title,
            work: { [interaction, fileSystems] monitor -> (JobResult, Summary) in
                var result: JobResult
                switch makeJob(monitor.cancellation) {
                case .failure(let refusal):
                    result = JobResult(refusal: refusal.message)

                case .success(let job):
                    let bridge = JobBridge(monitor: monitor, interaction: interaction, fileSystems: fileSystems)
                    job.delegate = bridge
                    job.onRecord = record
                    job.wantsRecord = wantsRecord
                    // A window is redrawn a few dozen times a second at most; more reports are wasted.
                    job.progressInterval = 0.04
                    // The job holds its delegate weakly; the bridge must live as long as the job runs.
                    result = withExtendedLifetime(bridge) { job.run() }
                }
                return (result, summary(result))
            },
            completion: { [interaction] result, summary in
                operationLog?.flushSoon()
                if let refusal = result.refusal, !refusal.isEmpty {
                    interaction.inform(refusal, detail: "", style: .warning)
                }
                completion(result, summary)
            }
        )
    }

    /// Runs a quick change of the file system off the main thread and comes back with its
    /// error, if any.
    internal func change(
        _ title: String,
        _ work: @escaping @Sendable (CancellationFlag) throws -> Void,
        then completion: @escaping @MainActor ((any Error)?) -> Void
    ) {
        kernel.jobs.run(
            title: title,
            work: { monitor -> (any Error)? in
                do {
                    try work(monitor.cancellation)
                    return nil
                } catch {
                    return error
                }
            },
            completion: completion
        )
    }

    /// Where relative targets of an operation in `directory` count from: the real folder
    /// behind a branch view; for a list of files from anywhere, which has no folder of its
    /// own, the folder of the first item.
    internal func base(of directory: URL, first: FileItem) -> URL {
        let real = RealLocation.resolve(directory, in: fileSystems)
        if RealLocation.takesNames(real, in: fileSystems) {
            return real
        }
        return first.url.deletingLastPathComponent()
    }

    /// With "keep going on errors" nobody was asked while the job ran; the user hears of the
    /// failures now.
    internal func reportFailures(of result: JobResult, options: TransferOptions) {
        guard options.skipsErrors, result.failureCount > 0 else {
            return
        }
        let more = result.failureCount > result.failures.count ? "\n…" : ""
        interaction.inform(
            "\(result.failureCount) item(s) could not be processed.",
            detail: result.failures.joined(separator: "\n") + more,
            style: .warning
        )
    }

    /// The operands of a command and the first of them.
    ///
    /// The commands are offered only where there are operands.
    internal func withOperands(_ body: (Picked, FileItem) -> Void) {
        let picked = Picked(source.model)
        if let first = picked.first {
            body(picked, first)
        }
    }

    deinit {
        // Nothing to release: the log writes on its own queue and lets go of its file there.
    }
}
