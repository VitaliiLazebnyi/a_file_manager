import FuzzCore

@testable import CompareContentPlugin

// MARK: myers

/// Checks that `segments` cover both sides in order, that equal segments are equal, and that applying
/// them to `first` gives `second`.
internal func checkSegments<T: Equatable>(
    _ segments: [DiffSegment],
    _ first: [T],
    _ second: [T],
    _ key: String,
    _ detail: @autoclosure () -> String
) {
    var (left, right) = (0, 0)
    for segment in segments {
        fzCheck(segment.a.lowerBound == left && segment.b.lowerBound == right, key + "-cover", detail())
        fzCheck(!(segment.a.isEmpty && segment.b.isEmpty), key + "-empty-segment", detail())
        if segment.isEqual {
            fzCheck(
                segment.a.count == segment.b.count && segment.a.upperBound <= first.count
                    && segment.b.upperBound <= second.count && Array(first[segment.a]) == Array(second[segment.b]),
                key + "-equal-not-equal",
                detail()
            )
        }
        (left, right) = (segment.a.upperBound, segment.b.upperBound)
    }
    fzCheck(left == first.count && right == second.count, key + "-cover-end", detail())
    fzCheck(Myers.apply(segments, to: first, from: second) == second, key + "-apply", detail())
}

/// The seeds of `myers`: alphabet, cost limit, repetitions, then the two sequences.
@MainActor
internal func myersSeeds() -> [[UInt8]] {
    [
        [4, 0, 0] + Array("abcabba".utf8) + [0xFF] + Array("cbabac".utf8),
        [2, 3, 0] + Array("aabbaabbabab".utf8) + [0xFF] + Array("babababbbaaa".utf8),
        [3, 1, 0x85] + Array("abcabcaabbcc".utf8) + [0xFF] + Array("ccbbaacbacba".utf8),
        [1, 0, 0] + Array("aaaa".utf8) + [0xFF], [5, 2, 0x10, 0xFF, 1, 2, 3]
    ]
}

/// Myers on two integer sequences: a valid edit script, the shortest one without a cost limit.
@MainActor
internal func runMyers(_ bytes: [UInt8]) {
    var choices = Choices(bytes)
    let alphabet = 1 + Int(choices.byte()) % 7
    let limitByte = Int(choices.byte())
    let limit: Int? = limitByte.isMultiple(of: 4) ? nil : (limitByte >> 2) % 24
    let repeatByte = choices.byte()
    let times = repeatByte & 0x80 != 0 ? 1 + Int(repeatByte & 0x3F) : 1
    let one = choices.until(0xFF).map { Int($0) % alphabet }
    let two = choices.rest().map { Int($0) % alphabet }
    var first: [Int] = []
    var second: [Int] = []
    for round in 0..<times {
        first += one
        second += (round % 3 == 2 ? two.reversed() : two)
    }
    let detail =
        "alphabet \(alphabet) limit \(String(describing: limit)) a=\(first.prefix(80)) b=\(second.prefix(80))"
        + " (\(first.count),\(second.count))"
    let segments = Myers.diff(first, second, costLimit: limit)
    checkSegments(segments, first, second, "myers", detail)
    if first.count * second.count <= 60_000 {
        let best = first.count + second.count - 2 * lcs(first, second)
        let got = Myers.editDistance(segments)
        fzCheck(got >= best, "myers-distance-below-optimum", detail)
        if limit == nil {
            fzCheck(got == best, "myers-not-shortest", detail + " got \(got) best \(best)")
        }
    }
    // the UTF-16 overload
    let wideFirst = first.map { UInt16($0 &* 9_973 & 0xFFFF) }
    let wideSecond = second.map { UInt16($0 &* 9_973 & 0xFFFF) }
    if wideFirst.count + wideSecond.count <= 4_000 {
        let wide = Myers.diff(wideFirst, wideSecond, costLimit: limit)
        checkSegments(wide, wideFirst, wideSecond, "myers16", detail)
    }
}

/// The `myers` target.
@MainActor
internal func myersTarget() -> FuzzTarget {
    FuzzTarget("myers", maxLen: 1 << 15, seeds: myersSeeds, run: runMyers)
}
