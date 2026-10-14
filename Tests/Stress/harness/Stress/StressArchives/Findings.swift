import Foundation
import StressKit

/// The invariant violations seen so far, counted by kind, with a few examples of each.
///
/// Unchecked: `violations` and `examples` are only touched while `lock` is held.
internal final class Findings: @unchecked Sendable {
    /// The one record of the process.
    internal static let shared = Findings()

    /// Guards `violations` and `examples`.
    private let lock = NSLock()
    /// How often each kind was seen.
    private var violations: [String: Int] = [:]
    /// The first examples of each kind.
    private var examples: [String: [String]] = [:]

    /// Whether nothing was seen.
    internal var isEmpty: Bool {
        lock.withLock { violations.isEmpty }
    }

    /// Records one violation of `kind`; the first six of a kind are printed.
    internal func violation(_ kind: String, _ detail: String) {
        let shows = lock.withLock {
            violations[kind, default: 0] += 1
            let shows = examples[kind, default: []].count < 6
            if shows {
                examples[kind, default: []].append(detail)
            }
            return shows
        }
        if shows {
            say("!! VIOLATION [\(kind)] \(detail)")
        }
    }

    /// Prints every kind with its count and examples.
    internal func summary() {
        lock.withLock {
            say("\n==== INVARIANT VIOLATIONS ====")
            if violations.isEmpty {
                say("none")
            }
            for (kind, count) in violations.sorted(by: { $0.key < $1.key }) {
                say("\(kind): \(count)")
                for example in examples[kind] ?? [] {
                    say("    e.g. \(example)")
                }
            }
        }
    }

    deinit {
        // Nothing to release.
    }
}
