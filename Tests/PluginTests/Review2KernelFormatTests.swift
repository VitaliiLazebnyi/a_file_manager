import AFMContracts
import AFMKernel
import Foundation
import Testing

/// Review 2, K035/K036: the formats shared by the whole program take any number, on any thread.
@Suite
struct Review2KernelFormat {
    @Test
    func anyNumberIsASize() {
        #expect(Format.kilobytes(.max) == "9,007,199,254,740,992 k")
        #expect(Format.kilobytes(.max - 512) == "9,007,199,254,740,991 k")
        #expect(Format.kilobytes(.min) == "-9,007,199,254,740,992 k")
        #expect(
            Format.kilobytes(0) == "0 k" && Format.kilobytes(511) == "0 k" && Format.kilobytes(512) == "1 k"
                && Format.kilobytes(1_535) == "1 k"
        )
        #expect(Format.kilobytes(1_536) == "2 k" && Format.kilobytes(3_693_568) == "3,607 k")
        #expect(Format.bytes(.max) == "9,223,372,036,854,775,807" && Format.bytes(.min) == "-9,223,372,036,854,775,808")
        #expect(
            Format.bytes(0) == "0" && Format.bytes(999) == "999" && Format.bytes(1_000) == "1,000"
                && Format.bytes(250_944) == "250,944"
        )
        #expect(
            Format.bytes(-1) == "-1" && Format.bytes(-1_000) == "-1,000" && Format.bytes(-123_456) == "-123,456"
                && Format.bytes(100_000) == "100,000"
        )
        #expect(Format.shortSize(.max).hasSuffix(" T") && Format.shortSize(.min).hasSuffix(" b"))
    }

    @Test
    func speedsAndTimesThatAreNoNumbersAreShownAsSomething() {
        for speed in [Double.nan, .infinity, -.infinity, 1e300, -1e300, -5, 0] {
            #expect(Format.speed(speed).hasSuffix("/s"))
        }
        #expect(Format.speed(11_597_250) == "11.06 M/s")
        for time in [Double.nan, .infinity, -.infinity, 1e300, -1e300] {
            #expect(!Format.duration(time).isEmpty)
        }
        #expect(
            Format.duration(8) == "8 s" && Format.duration(80) == "1 min 20 s" && Format.duration(7_500) == "2 h 05 min"
        )
    }

    @Test
    func sumsOfSizesStopAtTheEndsOfTheRange() {
        #expect(
            Int64.max.addingSaturated(1) == .max && Int64.min.addingSaturated(-1) == .min
                && Int64(5).addingSaturated(-7) == -2
        )
        #expect(Int64(saturating: UInt64.max) == .max && Int64(saturating: UInt32(7)) == 7)
        #expect(Int.max.addingSaturated(1) == .max)
    }

    @Test
    func namesFromOutsideAreShownWithoutWhatWouldMislead() {
        #expect(
            Format.displayName("report.txt") == "report.txt" && Format.displayName("été 写真 👨‍👩‍👧.jpg") == "été 写真 👨‍👩‍👧.jpg"
        )
        #expect(Format.displayName("a\nb\tc") == "a<U+000A>b<U+0009>c")
        #expect(Format.displayName("photo\u{202E}gpj.exe") == "photo<U+202E>gpj.exe")
        #expect(
            Format.displayName("a\u{200B}b\u{2028}c\u{FEFF}\u{7F}\u{0}")
                == "a<U+200B>b<U+2028>c<U+FEFF><U+007F><U+0000>"
        )
    }

    @Test
    func groupingDigitsIsSafeOnManyThreadsAtOnce() {
        let wrong = Parallel.map(Array(0..<20_000)) { index -> Bool in
            let value = Int64(index) * 1_000_003
            return Format.bytes(value).replacingOccurrences(of: ",", with: "") != String(value)
        }
        #expect(!wrong.contains(true))
    }
}
