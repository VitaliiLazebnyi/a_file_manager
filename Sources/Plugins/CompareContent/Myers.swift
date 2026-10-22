public import AFMKernel
import Foundation

/// A stretch of two sequences that is either the same in both or differs: `a` is deleted and
/// `b` inserted in its place (either may be empty).
///
/// The segments of a diff cover both sequences completely, in order.
public struct DiffSegment: Equatable, Sendable {
    public let a: Range<Int>
    public let b: Range<Int>
    public let isEqual: Bool
}

/// The difference of two sequences by Myers' O(ND) algorithm in its linear-space form
/// ("An O(ND) Difference Algorithm and Its Variations", 1986): the middle of a shortest edit
/// path is found by searching from both ends, and the two halves are solved the same way.
///
/// Three things keep it fast on real files. Elements are first replaced by small numbers, so
/// a comparison is one integer compare whatever the length of the lines. Elements that do not
/// occur on the other side at all cannot be part of any match and are taken out before the
/// search. And for very large inputs the search for a middle gives up after a bounded effort
/// (large enough for hundreds of thousands of changed lines, see `defaultLimit`). Where it
/// does, the lines that occur exactly once on each side are matched first (the longest rising
/// run of them, as in the patience diff) and the stretches between them are solved on their own;
/// only where there are no such lines does it split at the furthest point either walk reached,
/// as GNU diff does. The result is then still a correct diff, but not always the shortest.
///
/// Pure and thread-safe: everything lives in the call.
public enum Myers {
    /// Below this many elements (after taking out the unmatched ones) the diff is always the
    /// shortest possible.
    public static let exactBelow = 20_000

    /// The most rounds one search for a middle takes on a large input.
    ///
    /// A search that is cut off costs about the square of its rounds and is repeated about `size /
    /// rounds` times, so the bound is chosen for a total of a few hundred million steps whatever
    /// the size; real files, whose differences number thousands, never come near it.
    static func defaultLimit(forSize size: Int) -> Int? {
        size < exactBelow ? nil : max(256, min(8_192, 250_000_000 / size))
    }

    /// `costLimit` bounds the effort per split; nil chooses by size.
    ///
    /// The result is cut short (everything left counts as different) when `cancellation` is set.
    public static func diff<Element: Hashable>(
        _ a: [Element],
        _ b: [Element],
        costLimit: Int? = nil,
        cancellation: CancellationFlag? = nil
    ) -> [DiffSegment] {
        var numbers: [Element: Int32] = [:]
        func number(_ element: Element) -> Int32 {
            if let known = numbers[element] {
                return known
            }
            let next = Int32(numbers.count)
            numbers[element] = next
            return next
        }
        let (first, second) = (a.map(number), b.map(number))
        return segments(
            of: matching(first, second, kinds: numbers.count, costLimit: costLimit, cancellation: cancellation),
            counts: (a.count, b.count)
        )
    }

    /// The same for sequences of UTF-16 units: a unit is its own small number, so no table of
    /// elements is built.
    public static func diff(_ a: [UInt16], _ b: [UInt16], costLimit: Int? = nil, cancellation: CancellationFlag? = nil)
        -> [DiffSegment]
    {
        segments(
            of: matching(
                a.map { Int32($0) },
                b.map { Int32($0) },
                kinds: 1 << 16,
                costLimit: costLimit,
                cancellation: cancellation
            ),
            counts: (a.count, b.count)
        )
    }

    /// The sequence the segments turn `a` into; equal to `b` for a diff of `a` and `b`.
    public static func apply<Element>(_ segments: [DiffSegment], to a: [Element], from b: [Element]) -> [Element] {
        segments.flatMap { $0.isEqual ? a[$0.a] : b[$0.b] }
    }

    /// The number of deleted plus inserted elements.
    public static func editDistance(_ segments: [DiffSegment]) -> Int {
        segments.filter { !$0.isEqual }.reduce(0) { $0 + $1.a.count + $1.b.count }
    }

    // MARK: Matching

    /// For every element of `a` the position of its partner in `b`, or -1.
    ///
    /// The partners rise with the positions.
    static func matching(_ a: [Int32], _ b: [Int32], kinds: Int, costLimit: Int?, cancellation: CancellationFlag?)
        -> [Int]
    {
        var inA = [Bool](repeating: false, count: kinds)
        var inB = [Bool](repeating: false, count: kinds)
        for element in a { inA[Int(element)] = true }
        for element in b { inB[Int(element)] = true }
        let keptA = a.indices.filter { inB[Int(a[$0])] }
        let keptB = b.indices.filter { inA[Int(b[$0])] }
        let (shortA, shortB) = (keptA.map { a[$0] }, keptB.map { b[$0] })

        let size = shortA.count + shortB.count
        let limit = costLimit ?? defaultLimit(forSize: size)
        var match = [Int](repeating: -1, count: a.count)
        var pending = [(shortA.startIndex, shortA.endIndex, shortB.startIndex, shortB.endIndex)]
        // The two walks' tables are made once, for the largest split: with a limit the walks
        // stop after `limit` rounds, so that bounds their size, not the length of the input.
        let widest = (size + 1) / 2 + 1
        let reach = limit.map { min(widest, $0 + 1) } ?? widest
        let tables = UnsafeMutablePointer<Int>.allocate(capacity: 2 * (2 * reach + 2))
        defer { tables.deallocate() }
        var counts = AnchorCounts(kinds: kinds)
        shortA.withUnsafeBufferPointer { first in
            shortB.withUnsafeBufferPointer { second in
                while var (aLow, aHigh, bLow, bHigh) = pending.popLast() {
                    if cancellation?.isCancelled == true { break }
                    while aLow < aHigh, bLow < bHigh, first[aLow] == second[bLow] {
                        match[keptA[aLow]] = keptB[bLow]
                        aLow += 1
                        bLow += 1
                    }
                    while aLow < aHigh, bLow < bHigh, first[aHigh - 1] == second[bHigh - 1] {
                        match[keptA[aHigh - 1]] = keptB[bHigh - 1]
                        aHigh -= 1
                        bHigh -= 1
                    }
                    guard aLow < aHigh, bLow < bHigh,
                        let split = middle(
                            UnsafeBufferPointer(rebasing: first[aLow..<aHigh]),
                            UnsafeBufferPointer(rebasing: second[bLow..<bHigh]),
                            limit: limit,
                            tables: tables,
                            reach: reach
                        )
                    else { continue }
                    if !split.isExact {
                        // The search was cut off. Lines that both sides have exactly once are fixed points
                        // that a block moved or deleted far away cannot lead astray.
                        let anchors = uniqueAnchors(first, second, aLow, aHigh, bLow, bHigh, counts: &counts)
                        if !anchors.isEmpty {
                            var (a, b) = (aLow, bLow)
                            for anchor in anchors {
                                pending.append((a, anchor.a, b, anchor.b))
                                match[keptA[anchor.a]] = keptB[anchor.b]
                                (a, b) = (anchor.a + 1, anchor.b + 1)
                            }
                            pending.append((a, aHigh, b, bHigh))
                            continue
                        }
                    }
                    pending.append((aLow, aLow + split.x, bLow, bLow + split.y))
                    pending.append((aLow + split.x, aHigh, bLow + split.y, bHigh))
                }
            }
        }
        return match
    }

    /// A point on a shortest edit path of two sequences that share neither a start nor an
    /// end, found by walking from both corners until the walks meet.
    ///
    /// Nil when the sequences have nothing in common. With a `limit`, the walks stop after that
    /// many rounds and the point is the furthest either of them reached (`isExact` is false then).
    private static func middle(
        _ a: UnsafeBufferPointer<Int32>,
        _ b: UnsafeBufferPointer<Int32>,
        limit: Int?,
        tables: UnsafeMutablePointer<Int>,
        reach: Int
    ) -> (x: Int, y: Int, isExact: Bool)? {
        let (n, m) = (a.count, b.count)
        let rounds = min((n + m + 1) / 2, limit.map { $0 + 1 } ?? Int.max)
        let offset = rounds
        let length = 2 * rounds + 2
        // Furthest x reached on each diagonal, walking forward (v1) and backward (v2); the
        // part of the shared tables this split uses is cleared.
        let v1 = tables
        let v2 = tables + (2 * reach + 2)
        v1.update(repeating: -1, count: length)
        v2.update(repeating: -1, count: length)
        v1[offset + 1] = 0
        v2[offset + 1] = 0
        let delta = n - m
        // With an odd difference in length the forward walk closes the gap, else the backward.
        let front = delta % 2 != 0
        var (k1Start, k1End, k2Start, k2End) = (0, 0, 0, 0)

        for d in 0..<rounds {
            var k1 = -d + k1Start
            while k1 <= d - k1End {
                let slot = offset + k1
                var x1 = (k1 == -d || (k1 != d && v1[slot - 1] < v1[slot + 1])) ? v1[slot + 1] : v1[slot - 1] + 1
                var y1 = x1 - k1
                while x1 < n, y1 < m, a[x1] == b[y1] {
                    x1 += 1
                    y1 += 1
                }
                v1[slot] = x1
                if x1 > n {
                    k1End += 2
                } else if y1 > m {
                    k1Start += 2
                } else if front {
                    let other = offset + delta - k1
                    if other >= 0, other < length, v2[other] != -1, x1 >= n - v2[other] {
                        return (x1, y1, true)
                    }
                }
                k1 += 2
            }
            var k2 = -d + k2Start
            while k2 <= d - k2End {
                let slot = offset + k2
                var x2 = (k2 == -d || (k2 != d && v2[slot - 1] < v2[slot + 1])) ? v2[slot + 1] : v2[slot - 1] + 1
                var y2 = x2 - k2
                while x2 < n, y2 < m, a[n - x2 - 1] == b[m - y2 - 1] {
                    x2 += 1
                    y2 += 1
                }
                v2[slot] = x2
                if x2 > n {
                    k2End += 2
                } else if y2 > m {
                    k2Start += 2
                } else if !front {
                    let other = offset + delta - k2
                    if other >= 0, other < length, v1[other] != -1 {
                        let x1 = v1[other]
                        let y1 = offset + x1 - other
                        if x1 >= n - x2 {
                            return (x1, y1, true)
                        }
                    }
                }
                k2 += 2
            }
            if let limit, d >= limit {
                // Out of effort: the point that either walk got furthest with, seen from the start
                // (forward) or from the end (backward); the one that progressed more is taken.
                var best: (x: Int, y: Int, progress: Int)?
                var k = -d + k1Start
                while k <= d - k1End {
                    let x = v1[offset + k]
                    let y = x - k
                    if x >= 0, x <= n, y >= 0, y <= m, x + y < n + m, x + y > (best?.progress ?? 0) {
                        best = (x, y, x + y)
                    }
                    k += 2
                }
                k = -d + k2Start
                while k <= d - k2End {
                    let x = v2[offset + k]
                    let y = x - k
                    if x >= 0, x <= n, y >= 0, y <= m, x + y < n + m, x + y > (best?.progress ?? 0) {
                        best = (n - x, m - y, x + y)
                    }
                    k += 2
                }
                if let best {
                    return (best.x, best.y, false)
                }
            }
        }
        return nil
    }

    /// Scratch tables for `uniqueAnchors`, made once per diff: how often each kind of element occurs
    /// in the stretch looked at (0, 1 or 2 for more) on either side, and where in the second one.
    struct AnchorCounts {
        var inA: [UInt8]
        var inB: [UInt8]
        var positionInB: [Int32]

        init(kinds: Int) {
            inA = [UInt8](repeating: 0, count: kinds)
            inB = [UInt8](repeating: 0, count: kinds)
            positionInB = [Int32](repeating: 0, count: kinds)
        }
    }

    /// The longest run, rising on both sides, of the elements that occur exactly once in each of
    /// the two stretches: pairs of positions (patience diff).
    ///
    /// Empty when there are none.
    private static func uniqueAnchors(
        _ a: UnsafeBufferPointer<Int32>,
        _ b: UnsafeBufferPointer<Int32>,
        _ aLow: Int,
        _ aHigh: Int,
        _ bLow: Int,
        _ bHigh: Int,
        counts: inout AnchorCounts
    ) -> [(a: Int, b: Int)] {
        for i in aLow..<aHigh {
            let v = Int(a[i])
            if counts.inA[v] < 2 { counts.inA[v] += 1 }
        }
        for j in bLow..<bHigh {
            let v = Int(b[j])
            if counts.inB[v] < 2 { counts.inB[v] += 1 }
            counts.positionInB[v] = Int32(truncatingIfNeeded: j)
        }
        // Piles of the patience sort: the smallest end position in b of a rising run of each length.
        var tails: [Int] = []
        var tailIndex: [Int] = []
        var candidates: [(a: Int, b: Int, previous: Int)] = []
        for i in aLow..<aHigh {
            let v = Int(a[i])
            guard counts.inA[v] == 1, counts.inB[v] == 1 else { continue }
            let j = Int(counts.positionInB[v])
            var (low, high) = (0, tails.count)
            while low < high {
                let middle = (low + high) / 2
                if tails[middle] < j { low = middle + 1 } else { high = middle }
            }
            candidates.append((i, j, low > 0 ? tailIndex[low - 1] : -1))
            if low == tails.count {
                tails.append(j)
                tailIndex.append(candidates.count - 1)
            } else {
                tails[low] = j
                tailIndex[low] = candidates.count - 1
            }
        }
        for i in aLow..<aHigh {
            let v = Int(a[i])
            counts.inA[v] = 0
        }
        for j in bLow..<bHigh {
            let v = Int(b[j])
            counts.inB[v] = 0
        }
        guard var current = tailIndex.last else {
            return []
        }
        var anchors: [(a: Int, b: Int)] = []
        while current >= 0 {
            anchors.append((candidates[current].a, candidates[current].b))
            current = candidates[current].previous
        }
        return anchors.reversed()
    }

    /// Turns the partners into segments.
    static func segments(of match: [Int], counts: (a: Int, b: Int)) -> [DiffSegment] {
        var result: [DiffSegment] = []
        var (i, j) = (0, 0)
        while i < counts.a || j < counts.b {
            let (equalA, equalB) = (i, j)
            while i < counts.a, match[i] == j {
                i += 1
                j += 1
            }
            if i > equalA { result.append(DiffSegment(a: equalA..<i, b: equalB..<j, isEqual: true)) }
            let (differentA, differentB) = (i, j)
            while i < counts.a, match[i] == -1 { i += 1 }
            j = i < counts.a ? match[i] : counts.b
            if i > differentA || j > differentB {
                result.append(DiffSegment(a: differentA..<i, b: differentB..<j, isEqual: false))
            }
        }
        return result
    }
}
