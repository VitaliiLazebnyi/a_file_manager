import AFMKernel
import Foundation

/// Runs a child process to its end and collects what it writes.
///
/// **Threading.** `run` blocks until the child has ended and is meant for a job's thread. The
/// child's output arrives on a queue of the system and is kept behind a lock; the pipe is
/// emptied while the child runs, so a child that writes a lot never waits for a full pipe.
/// Cancelling asks the child to end (SIGTERM) and, if it does not listen, ends it (SIGKILL).
internal struct ProcessRunner {
    /// All state is guarded by `lock`.
    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var truncated = false

        var contents: (data: Data, truncated: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (data, truncated)
        }

        func append(_ block: Data) {
            lock.lock()
            defer { lock.unlock() }
            let room = ProcessRunner.outputLimit - data.count
            if block.count > room { truncated = true }
            if room > 0 { data.append(block.prefix(room)) }
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The most output that is kept; a command that prints without end must not fill memory.
    internal static let outputLimit = 8 * 1_024 * 1_024

    /// The program to start.
    internal let executable: URL
    /// The arguments it is started with, each handed on as one word.
    internal let arguments: [String]
    /// The folder it starts in; this process's when nil.
    internal let directory: URL?
    /// Without, nothing is read: the child writes into the void and is not waited for longer
    /// than it takes the shell to start it.
    internal var collectsOutput = true
    /// The child's environment; this program's unless told otherwise.
    internal var environment = ProcessInfo.processInfo.environment

    /// Ends the shell and what it started: the whole group when the shell leads one of its own,
    /// else the shell alone (the group is then ours too).
    private static func kill(_ pid: pid_t) {
        if getpgid(pid) == pid { _ = Darwin.kill(-pid, SIGKILL) }
        _ = Darwin.kill(pid, SIGKILL)
    }

    /// Waits for `process` to end, calling `tick` about every 50 ms meanwhile.
    ///
    /// When `cancellation` is set the child is asked to end, and ended two seconds later if it
    /// is still there. Returns whether that happened.
    private static func waitForEnd(
        of process: Process,
        exited: DispatchSemaphore,
        cancellation: CancellationFlag,
        tick: () -> Void
    ) -> Bool {
        var cancelled = false
        var askedToEnd: Date?
        while exited.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            tick()
            guard cancellation.isCancelled else { continue }
            cancelled = true
            if let asked = askedToEnd {
                if Date().timeIntervalSince(asked) > 2 { kill(process.processIdentifier) }
            } else {
                process.terminate()
                askedToEnd = Date()
            }
        }
        return cancelled
    }

    /// Runs the child to its end; `progress`, when there is one, is told now and then how many
    /// bytes have arrived.
    internal func run(cancellation: CancellationFlag, progress: ((Int) -> Void)?) -> ProcessOutcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let buffer = Buffer()
        let (exited, drained) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
        let pipe = attachOutput(of: process, to: buffer, drained: drained)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            pipe?.fileHandleForReading.readabilityHandler = nil
            // Foundation does not let go of the handler of a process that did not start.
            process.terminationHandler = nil
            return ProcessOutcome(failure: error.localizedDescription)
        }
        // The parent's copy of the writing end must go, or the end of the output never comes.
        try? pipe?.fileHandleForWriting.close()

        var outcome = ProcessOutcome()
        outcome.wasCancelled = Self.waitForEnd(of: process, exited: exited, cancellation: cancellation) {
            progress?(buffer.contents.data.count)
        }
        if let pipe {
            // What is still in the pipe is read; a grandchild that keeps the pipe open is not waited for.
            _ = drained.wait(timeout: .now() + .milliseconds(outcome.wasCancelled ? 100 : 500))
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        let (data, truncated) = buffer.contents
        outcome.output = String(repairingUTF8: data)
        outcome.isTruncated = truncated
        outcome.status = process.terminationStatus
        return outcome
    }

    /// Sends standard output and standard error of `process` into one pipe whose blocks go to
    /// `buffer`, signalling `drained` at the end of the output; the pipe, or nil when the output
    /// is not collected (it then goes nowhere).
    private func attachOutput(of process: Process, to buffer: Buffer, drained: DispatchSemaphore) -> Pipe? {
        guard collectsOutput else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            return nil
        }
        let both = Pipe()
        process.standardOutput = both
        process.standardError = both
        both.fileHandleForReading.readabilityHandler = { handle in
            let block = handle.availableData
            if block.isEmpty {
                // End of file: every writer has closed its end.
                handle.readabilityHandler = nil
                drained.signal()
            } else {
                buffer.append(block)
            }
        }
        return both
    }
}
