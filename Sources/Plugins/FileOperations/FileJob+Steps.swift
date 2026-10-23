import AFMKernel
import Foundation

/// The steps every part of a job is made of: one step with its error question, the records
/// of the log, and the looks at the file system that end with the job.
extension FileJob {
    /// The flag for a call that tidies up.
    ///
    /// The job's own flag will not do: once the job is stopped it would end the very call that
    /// removes what the stopped step left behind. A local disk answers; a server that has stopped
    /// answering is waited for `cleanupPatience` and no longer, so that neither Cancel nor the end
    /// of the program hangs on it.
    internal func patience(with provider: any FileSystemProvider) -> CancellationFlag {
        let flag = CancellationFlag()
        guard provider.scheme != "file" else {
            return flag
        }
        Self.patienceClock.asyncAfter(deadline: .now() + cleanupPatience) { flag.cancel() }
        return flag
    }

    /// The entry at `url`, asked in a way that ends when the job is cancelled.
    ///
    /// Throws then, since "nothing there" would be a wrong answer to act on. Not for cleaning up.
    internal func entry(at url: URL) throws -> FileItem? {
        let found = (try? fileSystems.provider(for: url))?.item(at: url, cancellation: cancellation)
        if found == nil, cancellation.isCancelled { throw Cancelled() }
        return found
    }

    /// Where a top-level source goes in `target`.
    internal func destination(for source: URL, in target: TargetSpec) -> URL {
        if let name = newNames[source.locationKey] {
            return source.deletingLastPathComponent().appending(name: name)
        }
        return target.url(for: source.lastPathComponent)
    }

    /// The delegate, or the end of the job when it is gone: a job without one stops at its first
    /// question instead of guessing an answer.
    internal func delegateOrStop() throws -> any FileJobDelegate {
        guard let delegate else { throw Cancelled() }
        return delegate
    }

    /// The job ends because of an answer (Abort, Cancel in a question) or an error it cannot
    /// go on after: the workers stop, and so does whatever waits on the job's own flag, such
    /// as a progress window that holds the job back while it is paused.
    internal func halt() {
        stop.cancel()
        cancellation.cancel()
    }

    /// Counts and logs something that went wrong without a question being asked about it.
    internal func note(_ verb: OperationRecord.Verb, at url: URL, _ message: String) {
        counters.withLock {
            failureCount += 1
            if failures.count < 20 { failures.append("\(display(url)): \(message)") }
        }
        record(verb, url, nil, .failed(message))
    }

    /// Runs one step; on failure asks Skip / Skip all / Retry / Abort.
    ///
    /// Used on every thread of the job.
    internal func attempt(_ verb: OperationRecord.Verb, at url: URL, target: URL?, _ step: () throws -> Bool)
        throws -> Bool
    {
        do {
            return try step()
        } catch is Cancelled {
            throw Cancelled()
        } catch {
            // What fails because the job is being stopped is not a question for the user.
            if isStopping { throw Cancelled() }
            counters.withLock {
                failureCount += 1
                if failures.count < 20 { failures.append("\(display(url)): \(error.localizedDescription)") }
            }
            record(verb, url, target, .failed(error.localizedDescription))
            switch try answer(to: error, at: url) {
            case .skip, .skipAll:
                record(verb, url, target, .skipped)
                return false

            case .retry:
                return try attempt(verb, at: url, target: target, step)

            case .abort:
                throw Cancelled()
            }
        }
    }

    /// What to do after the step at `url` failed with `error`: the rule "skip all", or the
    /// user's answer, asked under `decisions`.
    private func answer(to error: any Error, at url: URL) throws -> ErrorChoice {
        try decisions.withLock {
            if skipAllErrors {
                return .skip
            }
            // Another worker's question may have ended the job while this one waited its turn.
            if isStopping { throw Cancelled() }
            let choice = try delegateOrStop().job(self, failedAt: url, error: error)
            if choice == .skipAll { skipAllErrors = true }
            if choice == .abort { halt() }
            return choice
        }
    }

    /// Throws `Cancelled` when the job is being stopped.
    internal func checkCancelled() throws {
        if isStopping { throw Cancelled() }
    }

    /// A location as the user is shown it.
    internal func display(_ url: URL) -> String {
        fileSystems.displayPath(url)
    }

    /// Hands a record of what was done to `onRecord`, unless nobody wants that kind.
    internal func record(
        _ verb: OperationRecord.Verb,
        _ source: URL,
        _ target: URL?,
        _ status: OperationRecord.Status
    ) {
        guard let onRecord, wantsRecord?(verb, status) ?? true else {
            return
        }
        onRecord(OperationRecord(verb, source: display(source), target: target.map(display), status: status))
    }

    /// A source is processed under its last name, like every entry of a folder: one that could
    /// lead out of its folder (`..` from a provider) is refused.
    ///
    /// False: reported and skipped.
    internal func hasSafeName(_ source: URL, verb: OperationRecord.Verb) throws -> Bool {
        let name = source.lastPathComponent
        if Self.isSafeName(name) {
            return true
        }
        add(Measure(items: 1))
        _ = try attempt(verb, at: source, target: nil) { throw FileJobError.unsafeName(name) }
        return false
    }
}
