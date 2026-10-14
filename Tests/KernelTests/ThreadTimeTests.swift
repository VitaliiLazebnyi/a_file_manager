import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// The clock for limits on work (`ThreadTime`): what the regular expressions of Find Files,
/// Selection and Multi-Rename are bounded by.
///
/// Their limits were measured by the clock, and a search then gave up on a text it would have
/// matched whenever the machine kept its thread waiting (seen as `aLongLineIsCutBetweenCharacters`
/// failing in a run under the thread sanitizer).
@Suite
internal struct ThreadTimeTests {
    /// Works on the calling thread until it has used `seconds` of its own time; returns a sum
    /// that is never zero, so the work cannot be left out.
    private static func work(for seconds: TimeInterval) -> Double {
        var sum = 0.0
        let start = ThreadTime.used
        while ThreadTime.used - start < seconds {
            for value in 0..<10_000 {
                sum += Double(value).squareRoot()
            }
        }
        return sum
    }

    /// A sleeping thread spends next to none of its time; working spends it, however long that
    /// takes by the clock.
    @Test
    internal func waitingCostsNoneOfAThreadsTimeAndWorkDoes() {
        let before = ThreadTime.used
        // The sleep is what is measured here: a thread that waits for 0.4 s by the clock.
        Thread.sleep(forTimeInterval: 0.4)
        let afterWaiting = ThreadTime.used
        // A limit of a quarter of a second is not spent by the wait.
        #expect(afterWaiting >= before && afterWaiting - before < 0.2)
        let sum = Self.work(for: 0.1)
        #expect(ThreadTime.used - afterWaiting >= 0.1 && sum > 0)
    }

    /// The time another thread works is not counted for the thread that waits for it.
    @Test
    internal func eachThreadHasItsOwn() throws {
        let mine = ThreadTime.used
        let other = try #require(
            OtherThread.result { () -> Double in
                let start = ThreadTime.used
                let sum = Self.work(for: 0.1)
                return ThreadTime.used - start + (sum > 0 ? 0 : 1)
            }
        )
        // The other thread used a tenth of a second; this one waited and used none of it.
        #expect(other >= 0.1 && ThreadTime.used - mine < 0.09)
    }
}
