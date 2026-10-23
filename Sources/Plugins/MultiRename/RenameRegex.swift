import AFMKernel
import Foundation

/// Runs the regular expression the user typed with a bound on its time.
///
/// Such an expression can take time that grows with every character of the name (`(a*)*b`), so it
/// is never run with `matches(in:)` or `firstMatch`: the matching is stopped from the progress
/// block of `enumerateMatches` once the budget has passed or the work was cancelled.
internal enum RenameRegex {
    /// What one name may take.
    internal static let budget: TimeInterval = 0.1

    /// The matches in `text` (only the first with `firstOnly`); none known when the expression took
    /// too long or the work was cancelled.
    internal static func matches(
        _ regex: NSRegularExpression,
        in text: String,
        firstOnly: Bool,
        guardian: RenameRegexGuard,
        cancelled: () -> Bool
    ) -> BoundedMatches<NSTextCheckingResult> {
        if guardian.isTripped || cancelled() {
            return .gaveUp
        }
        // (Processor time of this thread, not the clock: see `ThreadTime`.)
        let deadline = ThreadTime.used + budget
        var found: [NSTextCheckingResult] = []
        var timedOut = false
        regex.enumerateMatches(
            in: text,
            options: [.reportProgress],
            range: NSRange(location: 0, length: text.utf16.count)
        ) { result, _, stop in
            if let result {
                found.append(result)
                if firstOnly {
                    stop.pointee = true
                }
            } else if cancelled() || ThreadTime.used > deadline {
                timedOut = true
                stop.pointee = true
            }
        }
        if timedOut {
            if !cancelled() {
                guardian.recordTimeout()
            }
            return .gaveUp
        }
        return .found(found)
    }
}
