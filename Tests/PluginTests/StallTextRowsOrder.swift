import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin

/// The segments of a parallel index build are shown in file order: what a later segment has found while an
/// earlier one is still read is not shown before it.
@Suite
internal struct StallTextRowsOrder {
    /// Serves `data`; a read below `heldBelow` waits until a read at `releasingAt` or beyond was asked for, and
    /// notes how often the index had shown progress by then.
    private final class OrderedSource: ByteSource {
        private let data: Data
        private let heldBelow: Int64
        private let releasingAt: Int64
        private let progress: CovNetCount
        private let later = Signal<Int>()

        var length: Int64 { Int64(data.count) }

        /// The progress the index had shown when the later read came; nil before.
        var progressAtRelease: Int? { later.wait(seconds: 0) }

        init(_ data: Data, heldBelow: Int64, releasingAt: Int64, progress: CovNetCount) {
            self.data = data
            self.heldBelow = heldBelow
            self.releasingAt = releasingAt
            self.progress = progress
        }

        func read(at offset: Int64, count: Int) -> Data {
            if offset >= releasingAt, later.wait(seconds: 0) == nil { later.set(progress.value) }
            if offset < heldBelow { _ = later.wait() }
            let lower = Int(min(offset, length))
            return data.subdata(in: lower..<min(data.count, lower + count))
        }
    }

    /// Two segments of 8 MB, each read on a thread of its own.
    ///
    /// The first waits until the second has read 4 MB, the length after which a segment shows what
    /// it has found so far: the second is not the next to be shown, so nothing is shown until the
    /// first is read; then all rows are there, in order.
    @Test
    internal func aLaterSegmentShowsNothingBeforeTheEarlierOnes() {
        let line = String(repeating: "x", count: 79) + "\n"
        let data = Data(String(repeating: line, count: (16 << 20) / 80).utf8)
        let progress = CovNetCount()
        let segment = 8 << 20
        let source = OrderedSource(
            data,
            heldBelow: Int64(segment),
            releasingAt: Int64(segment + (4 << 20)),
            progress: progress
        )
        let index = TextRowIndex(start: 0, reusing: nil) { count, work in
            let done = (0..<count).map { _ in Signal<Bool>() }
            for number in 0..<count {
                OtherThread.start {
                    work(number)
                    done[number].set(true)
                }
            }
            for signal in done { _ = signal.wait() }
        }
        index.build(
            source: source,
            content: 0..<Int64(data.count),
            encoding: .utf8,
            options: TextLayoutOptions(columns: 200, wordWrap: false),
            parallel: true,
            segmentSize: segment,
            cancellation: CancellationFlag()
        ) { progress.add() }
        #expect(source.progressAtRelease == 0)
        #expect(index.isComplete && index.rowCount == data.count / 80 && index.lineCount == data.count / 80)
    }
}
