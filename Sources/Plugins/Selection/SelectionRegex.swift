import AFMKernel
import Foundation

/// Counts the names a regular expression ran out of time on; shared by the threads that match
/// one mask. After a few timeouts the expression is given up: the rest of the names answer at
/// once instead of costing the budget each.
final class SelectionRegexTrip {
    private let lock = NSLock()
    private var timeouts = 0

    func recordTimeout() {
        lock.lock()
        timeouts += 1
        lock.unlock()
    }

    var hasTimedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timeouts > 0
    }

    var isTripped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timeouts >= 3
    }
}

/// Runs the regular expression of a `<` mask with a bound on its time. Such an expression can
/// take time that grows with every character of the name (`<(a+)+$`), so it is never run with
/// the plain `firstMatch`: the matching is stopped from the progress block of
/// `enumerateMatches` once the budget has passed or the work was cancelled.
enum SelectionRegex {
    /// What one name may take.
    static let budget: TimeInterval = 0.25

    static func matches(_ regex: NSRegularExpression, _ name: String, trip: SelectionRegexTrip, cancelled: () -> Bool)
        -> Bool
    {
        if trip.isTripped || cancelled() { return false }
        guard !name.isEmpty else { return regex.firstMatch(in: name, range: NSRange(location: 0, length: 0)) != nil }
        // (Processor time of this thread, not the clock: see `ThreadTime`.)
        let deadline = ThreadTime.used + budget
        var found = false
        var timedOut = false
        regex.enumerateMatches(
            in: name, options: [.reportProgress], range: NSRange(location: 0, length: name.utf16.count)
        ) { result, _, stop in
            if result != nil {
                found = true
                stop.pointee = true
            } else if cancelled() || ThreadTime.used > deadline {
                timedOut = true
                stop.pointee = true
            }
        }
        if timedOut, !cancelled() { trip.recordTimeout() }
        return found
    }
}
