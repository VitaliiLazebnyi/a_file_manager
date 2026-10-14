import Foundation
import StressKit

/// The invariant violations of the run, by kind, with the first few examples of each.
///
/// Unchecked: `counts` and `examples` are only read and written under `lock`.
internal final class Findings: @unchecked Sendable {
    /// The one record of the process.
    internal static let shared = Findings()

    /// Guards `counts` and `examples`.
    private let lock = NSLock()
    /// How often each kind was seen.
    private var counts: [String: Int] = [:]
    /// The first six details of each kind.
    private var examples: [String: [String]] = [:]

    /// Whether nothing was found.
    internal var isEmpty: Bool {
        lock.withLock { counts.isEmpty }
    }

    /// Records a violation of `kind`; the first six of a kind are printed at once.
    internal func violation(_ kind: String, _ detail: String) {
        let shows: Bool = lock.withLock {
            counts[kind, default: 0] += 1
            guard examples[kind, default: []].count < 6 else {
                return false
            }
            examples[kind, default: []].append(detail)
            return true
        }
        if shows {
            say("!! VIOLATION [\(kind)] \(detail)")
        }
    }

    /// Prints every kind with its count and examples.
    internal func summary() {
        let (seen, shown) = lock.withLock { (counts, examples) }
        say("\n==== INVARIANT VIOLATIONS ====")
        if seen.isEmpty {
            say("none")
        }
        for (kind, count) in seen.sorted(by: { $0.key < $1.key }) {
            say("\(kind): \(count)")
            for example in shown[kind] ?? [] {
                say("    e.g. \(example)")
            }
        }
    }

    deinit {
        // Nothing to release.
    }
}
