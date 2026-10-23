public import AFMKernel

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
    internal static func defaultLimit(forSize size: Int) -> Int? {
        size < exactBelow ? nil : max(256, min(8_192, 250_000_000 / size))
    }

    /// The segments that turn `first` into `second`; `costLimit` bounds the effort per split, nil chooses by size.
    ///
    /// The result is cut short (everything left counts as different) when `cancellation` is set.
    public static func diff<Element: Hashable>(
        _ first: [Element],
        _ second: [Element],
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
        let (firstNumbers, secondNumbers) = (first.map(number), second.map(number))
        return segments(
            of: matching(
                firstNumbers,
                secondNumbers,
                kinds: numbers.count,
                costLimit: costLimit,
                cancellation: cancellation
            ),
            counts: (first.count, second.count)
        )
    }

    /// The same for sequences of UTF-16 units: a unit is its own small number, so no table of
    /// elements is built.
    public static func diff(
        _ first: [UInt16],
        _ second: [UInt16],
        costLimit: Int? = nil,
        cancellation: CancellationFlag? = nil
    ) -> [DiffSegment] {
        segments(
            of: matching(
                first.map(Int32.init),
                second.map(Int32.init),
                kinds: 1 << 16,
                costLimit: costLimit,
                cancellation: cancellation
            ),
            counts: (first.count, second.count)
        )
    }

    /// The sequence the segments turn `first` into; equal to `second` for a diff of `first` and `second`.
    public static func apply<Element>(_ segments: [DiffSegment], to first: [Element], from second: [Element])
        -> [Element]
    {
        segments.flatMap { segment in segment.isEqual ? first[segment.first] : second[segment.second] }
    }

    /// The number of deleted plus inserted elements.
    public static func editDistance(_ segments: [DiffSegment]) -> Int {
        segments.filter { segment in !segment.isEqual }
            .reduce(0) { total, segment in total + segment.first.count + segment.second.count }
    }

    /// Turns the partners into segments.
    internal static func segments(of match: [Int], counts: (first: Int, second: Int)) -> [DiffSegment] {
        var result: [DiffSegment] = []
        var (inFirst, inSecond) = (0, 0)
        while inFirst < counts.first || inSecond < counts.second {
            let (equalFirst, equalSecond) = (inFirst, inSecond)
            while inFirst < counts.first, match[inFirst] == inSecond {
                inFirst += 1
                inSecond += 1
            }
            if inFirst > equalFirst {
                result.append(DiffSegment(first: equalFirst..<inFirst, second: equalSecond..<inSecond, isEqual: true))
            }
            let (differentFirst, differentSecond) = (inFirst, inSecond)
            while inFirst < counts.first, match[inFirst] == -1 {
                inFirst += 1
            }
            inSecond = inFirst < counts.first ? match[inFirst] : counts.second
            if inFirst > differentFirst || inSecond > differentSecond {
                result.append(
                    DiffSegment(first: differentFirst..<inFirst, second: differentSecond..<inSecond, isEqual: false)
                )
            }
        }
        return result
    }
}
