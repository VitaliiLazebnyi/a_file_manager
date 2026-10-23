import AFMContracts
import AFMKernel
import Foundation
import os

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

    // MARK: Helpers

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
    internal func attempt(_ verb: OperationRecord.Verb, at url: URL, target: URL? = nil, _ step: () throws -> Bool)
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
            let choice: ErrorChoice = try decisions.withLock {
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
            switch choice {
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

    internal func checkCancelled() throws {
        if isStopping { throw Cancelled() }
    }

    internal func display(_ url: URL) -> String {
        fileSystems.displayPath(url)
    }

    internal func record(_ verb: OperationRecord.Verb, _ source: URL, _ target: URL?, _ status: OperationRecord.Status)
    {
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
        _ = try attempt(verb, at: source) { throw FileJobError.unsafeName(name) }
        return false
    }
}
