import Foundation
import StressKit

/// What went wrong during the run: each kind of failure recorded once, counted every time.
///
/// Unchecked: `kinds` and `counts` are only read and written with `lock` held.
internal final class Failures: @unchecked Sendable {
    /// The one record of the process.
    internal static let shared = Failures()

    /// Guards `kinds` and `counts`.
    private let lock = NSLock()
    /// The first failure of each kind, with its detail, in the order they happened.
    private var kinds: [String] = []
    /// How often each kind happened.
    private var counts: [String: Int] = [:]

    /// Whether nothing failed.
    internal var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return kinds.isEmpty
    }

    /// The record of the process is `shared`.
    private init() {
        // Nothing to set up.
    }

    /// Counts a failure of `kind`.
    ///
    /// The first of its kind is kept and printed with its detail. Any thread.
    internal func record(_ kind: String, _ detail: () -> String) {
        lock.lock()
        counts[kind, default: 0] += 1
        let first = counts[kind] == 1
        if first {
            kinds.append(kind + ": " + detail())
        }
        lock.unlock()
        if first {
            say("FAIL " + kind + ": " + detail())
        }
    }

    /// Prints the failures and how often each happened.
    internal func report() {
        lock.lock()
        let first = kinds
        let copy = counts
        lock.unlock()
        say("\nFAILURES: \(first.count) kinds")
        for failure in first {
            say("  " + failure)
        }
        for (kind, count) in copy.sorted(by: { $0.key < $1.key }) {
            say("  count \(count): \(kind)")
        }
    }

    deinit {
        // Nothing to release.
    }
}

/// Records a failure of `kind`: once per kind, counted every time.
///
/// Any thread.
internal func fail(_ kind: String, _ detail: @autoclosure () -> String) {
    Failures.shared.record(kind, detail)
}
