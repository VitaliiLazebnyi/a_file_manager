import AFMKernel
import Foundation

/// Runs a regular expression the user typed with a bound on its time.
///
/// Such an expression can take time that grows with every character of the text (`(a+)+$`), so it
/// is never run with the plain `firstMatch`: the matching is stopped from the progress block of
/// `enumerateMatches` when the budget has passed or the work was cancelled, on whatever thread the
/// caller is.
internal enum FindRegex {
    /// How one bounded match ended.
    internal enum Outcome: Equatable {
        /// The text holds a match.
        case matched
        /// The budget passed, or the work was cancelled, before the match was decided.
        case timedOut
        /// The text holds no match.
        case unmatched
    }

    /// What one match may take.
    internal static let defaultBudget: TimeInterval = 0.25

    /// Whether `text` holds a match, within `budget` seconds of work.
    ///
    /// A cancelled run reports `timedOut`; whoever cancelled does not use the answer.
    internal static func firstMatch(
        _ regex: NSRegularExpression,
        in text: String,
        budget: TimeInterval,
        cancelled: () -> Bool
    ) -> Outcome {
        guard !text.isEmpty else {
            return regex.firstMatch(in: text, range: NSRange(location: 0, length: 0)) != nil ? .matched : .unmatched
        }
        // The budget is the thread's own processor time, not the clock: a thread that is kept
        // waiting by a busy machine has not used its budget (see `ThreadTime`).
        let deadline = ThreadTime.used + budget
        var outcome = Outcome.unmatched
        regex.enumerateMatches(
            in: text,
            options: [.reportProgress],
            range: NSRange(location: 0, length: text.utf16.count)
        ) { result, _, stop in
            if result != nil {
                outcome = .matched
                stop.pointee = true
            } else if cancelled() || ThreadTime.used > deadline {
                outcome = .timedOut
                stop.pointee = true
            }
        }
        return outcome
    }

    /// `firstMatch` within `defaultBudget` that also counts a timeout in `trip` and gives up at once on a
    /// tripped pattern.
    internal static func matches(
        _ regex: NSRegularExpression,
        in text: String,
        trip: RegexTrip?,
        cancelled: () -> Bool
    ) -> Bool {
        if trip?.isTripped == true {
            return false
        }
        switch firstMatch(regex, in: text, budget: defaultBudget, cancelled: cancelled) {
        case .matched:
            return true

        case .timedOut:
            if !cancelled() {
                trip?.recordTimeout()
            }
            return false

        case .unmatched:
            return false
        }
    }
}
