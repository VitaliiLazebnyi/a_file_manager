import Testing

@testable import AFMShell

/// The speed of a job and the time it has left, measured over its last seconds.
@Suite
internal struct InteractionTransferRateTests {
    /// Nothing is said before a second of measurements is there.
    @Test
    internal func needsASecondOfMeasurements() {
        var rate = TransferRate()
        #expect(rate.perSecond == nil)
        rate.add(amount: 0, at: 10)
        rate.add(amount: 500, at: 10.5)
        #expect(rate.perSecond == nil)
        #expect(rate.remaining(total: 1_000) == nil)
        rate.add(amount: 2_000, at: 12)
        #expect(rate.perSecond == 1_000)
        #expect(rate.remaining(total: 5_000) == 3)
    }

    /// Only the last seconds count: a job that speeds up is soon measured at its new speed.
    @Test
    internal func followsTheLastSecondsOnly() {
        var rate = TransferRate()
        // 100 per second for 10 s, then 1000 per second for 5 s.
        for second in 0...10 {
            rate.add(amount: Int64(second * 100), at: Double(second))
        }
        #expect(rate.perSecond == 100)
        for second in 11...15 {
            rate.add(amount: Int64(1_000 + (second - 10) * 1_000), at: Double(second))
        }
        #expect(rate.perSecond == 1_000)
        #expect(rate.remaining(total: 16_000) == 10)
    }

    /// A stalled job has no time left to tell; a finished one has none left; a reset forgets.
    @Test
    internal func stalledAndFinishedJobs() {
        var rate = TransferRate()
        rate.add(amount: 500, at: 0)
        rate.add(amount: 500, at: 3)
        #expect(rate.perSecond == 0)
        #expect(rate.remaining(total: 1_000) == nil)
        rate.add(amount: 1_000, at: 4)
        #expect(rate.remaining(total: 1_000) == 0)
        rate.reset()
        #expect(rate.perSecond == nil)
    }
}
