import AFMKernel
import Foundation

/// Counts the names a regular expression of Search & Replace ran out of time on.
///
/// Shared by the threads of one preview or run. After a few timeouts the expression is given up:
/// the rest of the names answer at once (`<Error!>`) instead of costing the budget each.
///
/// Unchecked `Sendable`: `timeouts` is guarded by `lock`.
internal final class RenameRegexGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var timeouts = 0
    private let limit = 3

    internal var hasTimedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timeouts > 0
    }

    internal var isTripped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timeouts >= limit
    }

    internal func recordTimeout() {
        lock.lock()
        timeouts += 1
        lock.unlock()
    }
}

/// Runs the regular expression the user typed with a bound on its time.
///
/// Such an expression can take time that grows with every character of the name (`(a*)*b`), so it
/// is never run with `matches(in:)` or `firstMatch`: the matching is stopped from the progress
/// block of `enumerateMatches` once the budget has passed or the work was cancelled.
internal enum RenameRegex {
    /// What one name may take.
    internal static let budget: TimeInterval = 0.1

    /// The matches in `text` (only the first with `firstOnly`); nil when the expression took too
    /// long or the work was cancelled.
    internal static func matches(
        _ regex: NSRegularExpression,
        in text: String,
        firstOnly: Bool,
        guardian: RenameRegexGuard,
        cancelled: () -> Bool
    ) -> [NSTextCheckingResult]? {
        if guardian.isTripped || cancelled() {
            return nil
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
                if firstOnly { stop.pointee = true }
            } else if cancelled() || ThreadTime.used > deadline {
                timedOut = true
                stop.pointee = true
            }
        }
        if timedOut {
            if !cancelled() { guardian.recordTimeout() }
            return nil
        }
        return found
    }
}

/// The plain (non-regex) search of Search & Replace: `*` stands for any run of characters and
/// `?` for one character.
///
/// Matched by hand in time proportional to the name times the mask, where a regular expression made
/// of the mask (`*a*a*a*b` as `^.*?a.*?a.*?a.*?b`) can take time that grows with the power of the
/// number of stars.
///
/// A run is as short as possible, except at the end of the text searched for, where it takes
/// the rest of the name. A `*` at the start anchors the match at the beginning of the name.
/// Neither a `*` nor a `?` stands for a line break, as the `.` of a regular expression does not.
internal struct WildcardMatcher {
    /// A `*`, or a character or `?`.
    private struct Piece {
        var isStar = false
        /// The character, `nil` for `?`; compared without regard to case unless the search respects it.
        var value: UInt32?
    }

    /// The name as it is compared: every character once in the form the search has (folded
    /// to lower case unless the search respects case), and where the line breaks are.
    ///
    /// Made once per name: folding a character asks the Unicode tables, and asking them again for
    /// every place a run was tried at was where the time of a long search went.
    private struct Subject {
        let values: [UInt32]
        let breaks: [Bool]
        var count: Int { values.count }
    }

    /// What one name may take, in the thread's own processor time, as for a regular
    /// expression (`RenameRegex.budget`): a search of many stars in a name of thousands of
    /// characters is still the name times the search for every place it can begin at.
    internal static let budget: TimeInterval = RenameRegex.budget

    private let pieces: [Piece]
    private let isAnchored: Bool
    private let caseSensitive: Bool

    internal init(_ search: String, caseSensitive: Bool) {
        self.caseSensitive = caseSensitive
        var pieces: [Piece] = []
        for scalar in search.unicodeScalars {
            switch scalar {
            case "*":
                pieces.append(Piece(isStar: true))

            case "?":
                pieces.append(Piece())

            default:
                pieces.append(Piece(value: caseSensitive ? scalar.value : Self.folded(scalar)))
            }
        }
        // A lone `*` is the greedy kind (the whole name), not an anchored lazy one.
        isAnchored = pieces.count > 1 && pieces[0].isStar
        self.pieces = pieces
    }

    internal static func folded(_ scalar: Unicode.Scalar) -> UInt32 {
        if scalar.isASCII {
            return scalar.value >= 0x41 && scalar.value <= 0x5A ? scalar.value + 32 : scalar.value
        }
        let lower = scalar.properties.lowercaseMapping.unicodeScalars
        return lower.count == 1 ? lower.first!.value : scalar.value
    }

    private static func isLineBreak(_ value: UInt32) -> Bool {
        value == 0x0A || value == 0x0D || value == 0x85 || value == 0x2028 || value == 0x2029
    }

    /// The matches in `text`, as ranges in UTF-16 units, found one after the other as
    /// `NSRegularExpression.matches(in:)` finds them: the next search starts where a match ended
    /// (an empty match is allowed there, unless it is the one just found), or one place on after an
    /// empty match. `firstOnly` stops at the first.
    internal func matches(in text: String, firstOnly: Bool) -> [NSRange] {
        scan(text, firstOnly: firstOnly, budget: .infinity, cancelled: { false }).ranges
    }

    /// The same within `budget` seconds of work: nil when that was not enough or the work was
    /// cancelled, as `RenameRegex.matches` answers for a regular expression (a timeout is
    /// counted in `guardian`, and a search given up three times is not tried again).
    internal func matches(in text: String, firstOnly: Bool, guardian: RenameRegexGuard, cancelled: () -> Bool)
        -> [NSRange]?
    {
        if guardian.isTripped || cancelled() {
            return nil
        }
        let found = scan(text, firstOnly: firstOnly, budget: Self.budget, cancelled: cancelled)
        guard found.isComplete else {
            if !cancelled() { guardian.recordTimeout() }
            return nil
        }
        return found.ranges
    }

    /// The matches, and whether the search got to the end (within `budget`, not cancelled).
    private func scan(_ text: String, firstOnly: Bool, budget: TimeInterval, cancelled: () -> Bool) -> (
        ranges: [NSRange], isComplete: Bool
    ) {
        guard !pieces.isEmpty else {
            return ([], true)
        }
        let scalars = Array(text.unicodeScalars)
        var offsets = [Int](repeating: 0, count: scalars.count + 1)
        for (index, scalar) in scalars.enumerated() { offsets[index + 1] = offsets[index] + scalar.utf16.count }
        let subject = Subject(
            values: scalars.map { caseSensitive ? $0.value : Self.folded($0) },
            breaks: scalars.map { Self.isLineBreak($0.value) }
        )
        // Looked at every few thousand steps: the clock is not asked for every character.
        let deadline = budget.isFinite ? ThreadTime.used + budget : .infinity
        var (steps, isOver) = (0, false)
        func goesOn() -> Bool {
            if isOver {
                return false
            }
            steps += 1
            if steps & 0xFFF == 0, cancelled() || ThreadTime.used > deadline { isOver = true }
            return !isOver
        }
        var ranges: [NSRange] = []
        var from = 0
        while from <= subject.count {
            guard let (start, end) = firstMatch(in: subject, from: from, goesOn: goesOn) else { break }
            ranges.append(NSRange(location: offsets[start], length: offsets[end] - offsets[start]))
            if firstOnly { break }
            from = end > start ? end : end + 1
        }
        return (ranges, !isOver)
    }

    private func firstMatch(in subject: Subject, from: Int, goesOn: () -> Bool) -> (Int, Int)? {
        if isAnchored {
            guard from == 0, let end = match(subject, at: 0, goesOn: goesOn) else {
                return nil
            }
            return (0, end)
        }
        var start = from
        while start <= subject.count, goesOn() {
            if let end = match(subject, at: start, goesOn: goesOn) {
                return (start, end)
            }
            start += 1
        }
        return nil
    }

    /// Where a match that begins at `start` ends.
    ///
    /// Each run of characters after a `*` is looked for at its first place: if the rest cannot be
    /// found after that, it cannot after any later one.
    private func match(_ subject: Subject, at start: Int, goesOn: () -> Bool) -> Int? {
        var position = start
        var index = 0
        while index < pieces.count {
            if pieces[index].isStar {
                // The run of characters up to the next star (or the end of the search).
                var end = index + 1
                while end < pieces.count, !pieces[end].isStar { end += 1 }
                if end == pieces.count, index == pieces.count - 1 {
                    // A star at the very end takes the rest of the name, up to a line break.
                    while position < subject.count, !subject.breaks[position] { position += 1 }
                    return position
                }
                let run = pieces[(index + 1)..<end]
                guard let found = firstOccurrence(of: run, in: subject, from: position, goesOn: goesOn) else {
                    return nil
                }
                position = found + run.count
                index = end
            } else {
                var end = index
                while end < pieces.count, !pieces[end].isStar { end += 1 }
                let run = pieces[index..<end]
                guard fits(run, in: subject, at: position) else {
                    return nil
                }
                position += run.count
                index = end
            }
        }
        return position
    }

    private func fits(_ run: ArraySlice<Piece>, in subject: Subject, at position: Int) -> Bool {
        guard position + run.count <= subject.count else {
            return false
        }
        var place = position
        for piece in run {
            if let wanted = piece.value {
                if subject.values[place] != wanted {
                    return false
                }
            } else if subject.breaks[place] {
                return false
            }
            place += 1
        }
        return true
    }

    /// The first place at or after `from` where `run` fits without a line break lying between
    /// `from` and it (a star does not run over one).
    private func firstOccurrence(of run: ArraySlice<Piece>, in subject: Subject, from: Int, goesOn: () -> Bool) -> Int?
    {
        var position = from
        while position + run.count <= subject.count, goesOn() {
            if fits(run, in: subject, at: position) {
                return position
            }
            guard position < subject.count, !subject.breaks[position] else {
                return nil
            }
            position += 1
        }
        return nil
    }
}
