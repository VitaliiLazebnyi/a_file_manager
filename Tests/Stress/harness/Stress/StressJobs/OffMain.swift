import FileOperationsPlugin
import Foundation
import StressKit

/// Runs `body` on a background thread while the main run loop goes on; its result.
@MainActor
internal func offMain<Value: Sendable>(_ body: @escaping @Sendable () -> Value) -> Value {
    let done = Shared<Value?>(nil)
    let thread = Thread {
        let value = body()
        DispatchQueue.main.async { done.value = value }
    }
    thread.stackSize = 16 << 20
    thread.start()
    pump(upTo: 3_600) { done.value != nil }
    guard let value = done.value else {
        preconditionFailure("the work on the background thread did not end within an hour")
    }
    return value
}

/// Records the errors and failures a job reported: they are only expected as a consequence of a
/// cancel (and then they should not be asked about at all).
internal func checkErrors(_ label: String, _ outcome: Outcome) {
    for error in outcome.errors.prefix(3) {
        Findings.shared.violation("job reported an error", "\(label): \(error)")
    }
    if outcome.result.failureCount > 0 {
        Findings.shared.violation(
            "job counted failures",
            "\(label): \(outcome.result.failureCount) \(outcome.result.failures.prefix(2))"
        )
    }
}

/// Records every temporary file below `bases`; what is below each, by the base's name.
internal func checkNoTemporaries(_ label: String, _ bases: [URL]) -> [String: Listing] {
    var all: [String: Listing] = [:]
    for base in bases {
        let found = Tree.walk(base)
        all[base.lastPathComponent] = found
        for path in found.files + found.folders where Tree.isTemporary(path) {
            Findings.shared.violation("temporary file left behind", "\(label): \(base.lastPathComponent)/\(path)")
        }
    }
    return all
}

/// The `RUN` line of one job.
internal func describe(_ kind: String, _ seed: Int, _ outcome: Outcome, _ interference: Interference) -> String {
    let cancel =
        interference.cancelAfter.map { String(format: "%.3fs%@", $0, interference.cancelsOffMain ? "(bg)" : "(main)") }
        ?? "-"
    return String(
        format: "RUN seed=%d %@ wall=%.2fs cancelAt=%@ sent=%@ cancelled=%@ completed=%d failures=%d reports=%d "
            + "pauses=%d threads=%d",
        seed,
        kind,
        outcome.wall,
        cancel,
        outcome.cancelSent ? "y" : "n",
        outcome.result.cancelled ? "y" : "n",
        outcome.result.completed.count,
        outcome.result.failureCount,
        outcome.reports,
        outcome.pauses,
        threadCount()
    )
}
