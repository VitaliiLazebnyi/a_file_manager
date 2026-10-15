import Foundation

/// Sorts a run of indexes in place, a long one on all cores: the indexes are dealt into
/// buckets of neighbouring values, which are then sorted at the same time; nothing is left to
/// merge on a single thread.
internal enum BucketSort {
    /// How many values of a sample stand for each bucket when the boundaries are chosen.
    private static let oversampling = 16

    /// Sorts `indexes` by `isBefore`, which must be a strict order (no two indexes equal) and
    /// is called from several threads at once.
    internal static func sort(
        _ indexes: UnsafeMutableBufferPointer<UInt32>,
        by isBefore: @Sendable (UInt32, UInt32) -> Bool
    ) {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        guard indexes.count > Sorter.parallelThreshold, cores > 1 else {
            var run = indexes
            run.sort(by: isBefore)
            return
        }
        let splitters = splitters(of: indexes, buckets: min(256, cores * 8), by: isBefore)
        let copy = Array(indexes)
        let pieces = ListWork.evenPieces(copy.count, cores * 4)
        let bucketOf = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: copy.count)
        defer { bucketOf.deallocate() }
        // Every piece below writes its own positions of `bucketOf`, and in the end its own
        // positions of `indexes`; everything else is only read.
        nonisolated(unsafe) let (buckets, target) = (bucketOf, indexes)
        let counts = Parallel.map(pieces) { piece in
            var counts = [Int](repeating: 0, count: splitters.count + 1)
            for position in piece {
                let bucket = bucket(of: copy[position], among: splitters, by: isBefore)
                buckets[position] = UInt8(truncatingIfNeeded: bucket)
                counts[bucket] += 1
            }
            return counts
        }
        let (starts, runs) = layout(counts)
        _ = Parallel.map(Array(pieces.indices)) { piece in
            var next = starts[piece]
            for position in pieces[piece] {
                let bucket = Int(buckets[position])
                target[next[bucket]] = copy[position]
                next[bucket] += 1
            }
        }
        _ = Parallel.map(runs) { run in
            var part = UnsafeMutableBufferPointer(rebasing: target[run])
            part.sort(by: isBefore)
        }
    }

    /// The boundaries between the buckets, from a sample spread over the indexes.
    private static func splitters(
        of indexes: UnsafeMutableBufferPointer<UInt32>,
        buckets: Int,
        by isBefore: (UInt32, UInt32) -> Bool
    ) -> [UInt32] {
        let sampleCount = buckets * oversampling
        let sample = (0..<sampleCount).map { indexes[$0 * indexes.count / sampleCount] }.sorted(by: isBefore)
        return (1..<buckets).map { sample[$0 * oversampling] }
    }

    /// The bucket of a value: the first whose boundary lies after it.
    private static func bucket(of value: UInt32, among splitters: [UInt32], by isBefore: (UInt32, UInt32) -> Bool)
        -> Int
    {
        var (low, high) = (0, splitters.count)
        while low < high {
            let middle = (low + high) / 2
            if isBefore(value, splitters[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }

    /// Where each piece puts its share of each bucket (`starts[piece][bucket]`), and the
    /// positions of each bucket, from how many values of each bucket each piece holds.
    private static func layout(_ counts: [[Int]]) -> (starts: [[Int]], runs: [Range<Int>]) {
        let bucketCount = counts[0].count
        var starts = [[Int]](repeating: [Int](repeating: 0, count: bucketCount), count: counts.count)
        var runs: [Range<Int>] = []
        var position = 0
        for bucket in 0..<bucketCount {
            let start = position
            for piece in counts.indices {
                starts[piece][bucket] = position
                position += counts[piece][bucket]
            }
            runs.append(start..<position)
        }
        return (starts, runs)
    }
}
