import Foundation
import Testing

@testable import AFMContracts

/// Review 2, second pass: G001, G003 and G004 of the general findings, all in `Format`.
@Suite struct Review2KernelP2Format {
    @Test func theLargestSizesAreWrittenAndNotTrappedOn() {
        // G001: a ZIP64 entry or a server may say any size; the status line shows it in k.
        #expect(Format.kilobytes(.max) == "9,007,199,254,740,992 k")
        #expect(
            Format.kilobytes(.max - 511) == "9,007,199,254,740,992 k"
                && Format.kilobytes(.max - 512) == "9,007,199,254,740,991 k"
        )
        #expect(Format.kilobytes(.min) == "-9,007,199,254,740,992 k")
        #expect(
            Format.kilobytes(0) == "0 k" && Format.kilobytes(511) == "0 k" && Format.kilobytes(512) == "1 k"
                && Format.kilobytes(1_536) == "2 k"
        )
        #expect(Format.bytes(.max) == "9,223,372,036,854,775,807" && Format.bytes(.min) == "-9,223,372,036,854,775,808")
        #expect(Format.shortSize(.max) == "8388608.00 T")
    }

    @Test func speedsAndTimesThatAreNoNumbersAreWrittenAndNotTrappedOn() {
        // G003: a speed over no time, an estimate from a speed of nothing.
        for value in [
            Double.nan, .infinity, -.infinity, 1e300, -1e300, Double.greatestFiniteMagnitude, 9.3e18, 0, -0.0, 0.4
        ] {
            #expect(Format.speed(value).hasSuffix("/s"), "\(value)")
            #expect(!Format.duration(value).isEmpty, "\(value)")
        }
        #expect(Format.speed(.nan) == "0 b/s" && Format.speed(-5) == "0 b/s" && Format.speed(2_048) == "2.00 k/s")
        #expect(Format.duration(.infinity) == Format.duration(1e300) && Format.duration(.nan).hasSuffix("min"))
        #expect(
            Format.duration(0) == "1 s" && Format.duration(59.2) == "1 min" && Format.duration(3_600) == "1 h 00 min"
        )
    }

    @Test func numbersAndDatesAreWrittenFromManyThreadsWhileTheRegionChanges() {
        // G004: no formatter is shared for numbers, and the one for dates is replaced, never
        // changed, when the region or the time zone does (the notifications are what the
        // system sends then).
        // The changes are posted to a center of the formatter's own: posted to the program's, they
        // reached every observer of the process on these threads, the date fields of other tests'
        // windows among them, which then crashed in AppKit off the main thread.
        let center = NotificationCenter()
        let dates = Format.Dates(center: center)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let expected = dates.string(from: date)
        #expect(!expected.isEmpty && expected == Format.date(date))
        let mismatches = NSLock()
        // Guarded by `mismatches`.
        nonisolated(unsafe) var wrong = 0
        DispatchQueue.concurrentPerform(iterations: 16) { thread in
            for round in 0..<2_000 {
                if thread == 0, round % 50 == 0 {
                    center.post(name: Notification.Name("kCFLocaleCurrentLocaleDidChangeNotification"), object: nil)
                    center.post(name: .NSSystemTimeZoneDidChange, object: nil)
                }
                let number = Int64(thread) * 1_000_000 + Int64(round)
                let isRight =
                    dates.string(from: date) == expected && Format.bytes(number).filter { $0 != "," } == String(number)
                if !isRight {
                    mismatches.lock()
                    wrong += 1
                    mismatches.unlock()
                }
            }
        }
        #expect(wrong == 0)
    }
}
