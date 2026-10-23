import AFMKernel
import Foundation

/// Runs the regular expression of a `<` mask with a bound on its time.
///
/// Such an expression can take time that grows with every character of the name (`<(a+)+$`), so it
/// is never run with the plain `firstMatch`: the matching is stopped from the progress block of
/// `enumerateMatches` once the budget has passed or the work was cancelled.
internal enum SelectionRegex {
    /// What one name may take.
    internal static let budget: TimeInterval = 0.25

    /// Whether the expression matches the name, false once the budget has passed, the trip has
    /// tripped or `cancelled` says so; a name that ran out of time is counted on `trip`.
    internal static func matches(
        _ regex: NSRegularExpression,
        _ name: String,
        trip: SelectionRegexTrip,
        cancelled: () -> Bool
    )
        -> Bool
    {
        if trip.isTripped || cancelled() {
            return false
        }
        guard !name.isEmpty else {
            return regex.firstMatch(in: name, range: NSRange(location: 0, length: 0)) != nil
        }
        // (Processor time of this thread, not the clock: see `ThreadTime`.)
        let deadline = ThreadTime.used + budget
        var found = false
        var timedOut = false
        regex.enumerateMatches(
            in: name,
            options: [.reportProgress],
            range: NSRange(location: 0, length: name.utf16.count)
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
