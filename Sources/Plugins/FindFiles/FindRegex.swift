import AFMKernel
import Foundation

/// Counts the regular expressions that ran out of time, so that a pattern which is too slow
/// for every name does not cost its time budget again for each of a million files: after a few
/// timeouts the pattern is taken as unusable and the rest answer at once. Shared by the
/// threads of one search.
final class RegexTrip {
    private let lock = NSLock()
    private var timeouts = 0
    private let limit: Int

    init(limit: Int = 3) {
        self.limit = limit
    }

    func recordTimeout() {
        lock.lock()
        timeouts += 1
        lock.unlock()
    }

    /// Whether any regular expression of the search ran out of time.
    var hasTimedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timeouts > 0
    }

    /// Whether enough of them did for the pattern to be given up.
    var isTripped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timeouts >= limit
    }
}

/// Runs a regular expression the user typed with a bound on its time. Such an expression can
/// take time that grows with every character of the text (`(a+)+$`), so it is never run with
/// the plain `firstMatch`: the matching is stopped from the progress block of
/// `enumerateMatches` when the budget has passed or the work was cancelled, on whatever thread
/// the caller is.
enum FindRegex {
    /// What one match may take.
    static let defaultBudget: TimeInterval = 0.25

    enum Outcome: Equatable {
        case matched, unmatched, timedOut
    }

    /// Whether `text` holds a match, within `budget` seconds of work. A cancelled run reports
    /// `timedOut`; whoever cancelled does not use the answer.
    static func firstMatch(
        _ regex: NSRegularExpression, in text: String, budget: TimeInterval = defaultBudget,
        cancelled: () -> Bool = { false }
    ) -> Outcome {
        guard !text.isEmpty else {
            return regex.firstMatch(in: text, range: NSRange(location: 0, length: 0)) != nil ? .matched : .unmatched
        }
        // The budget is the thread's own processor time, not the clock: a thread that is kept
        // waiting by a busy machine has not used its budget (see `ThreadTime`).
        let deadline = ThreadTime.used + budget
        var outcome = Outcome.unmatched
        regex.enumerateMatches(
            in: text, options: [.reportProgress], range: NSRange(location: 0, length: text.utf16.count)
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

    /// `firstMatch` that also counts a timeout in `trip` and gives up at once on a tripped pattern.
    static func matches(
        _ regex: NSRegularExpression, in text: String, trip: RegexTrip?, budget: TimeInterval = defaultBudget,
        cancelled: () -> Bool = { false }
    ) -> Bool {
        if trip?.isTripped == true { return false }
        switch firstMatch(regex, in: text, budget: budget, cancelled: cancelled) {
        case .matched: return true
        case .unmatched: return false

        case .timedOut:
            if !cancelled() { trip?.recordTimeout() }
            return false
        }
    }
}
