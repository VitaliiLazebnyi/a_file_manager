import Foundation
import Testing

@testable import AFMContracts

/// Corners of `Format` the other suites do not reach.
@Suite
internal struct CoreFormatTests {
    /// Negative sizes are rounded to the nearest kilobyte too, half a kilobyte and more away from zero.
    @Test
    internal func negativeKilobytesAreRoundedToTheNearest() {
        #expect(Format.kilobytes(-600) == "-1 k")
        #expect(Format.kilobytes(-512) == "0 k")
        #expect(Format.kilobytes(-1_024 - 600) == "-2 k")
        #expect(Format.kilobytes(600) == "1 k")
    }

    /// A date formatter follows a change of the time zone and lets go of its observers when it goes.
    @Test
    internal func datesFollowTheTimeZoneAndLetGoOfTheirObservers() {
        weak var gone: Format.Dates?
        do {
            let dates = Format.Dates()
            gone = dates
            let moment = Date(timeIntervalSince1970: 1_000_000_000)
            let before = dates.string(from: moment)
            NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
            #expect(dates.string(from: moment) == before)
        }
        #expect(gone == nil)
    }
}
