import Foundation
import Testing

@testable import NetworkPlugin

/// The corners of the listing formats that the other parser tests leave out.
@Suite
internal struct CoverageNetworkListings {
    /// A calendar in UTC.
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    /// 15 June 2024, 12:00 UTC.
    private static let now = Date(timeIntervalSince1970: 1_718_452_800)

    private func list(_ line: String) -> RemoteEntry? {
        FTPListParser.list(line, now: Self.now, calendar: Self.utc)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date? {
        Self.utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
    }

    /// MLSD skips facts without a value and the folder itself.
    @Test
    internal func mlsdSkipsFactsWithoutAValueAndTheFolderItself() {
        let entry = FTPListParser.mlsd("type=file;junk;size=12; notes.txt")
        #expect(entry == RemoteEntry(name: "notes.txt", isDirectory: false, size: 12))
        #expect(FTPListParser.mlsd("type=cdir; here") == nil)
        #expect(FTPListParser.mlsd("Type=PDIR; up") == nil)
    }

    /// MLST takes the line with and without its leading space.
    @Test
    internal func mlstTakesTheLineWithAndWithoutItsLeadingSpace() {
        #expect(FTPListParser.mlst(" type=dir; /pub/files")?.name == "files")
        #expect(FTPListParser.mlst("type=file;size=3; /pub/a.txt")?.size == 3)
        #expect(FTPListParser.mlst("type=file;size=3;") == nil)
    }

    /// A line without a name after the date is no entry.
    @Test
    internal func aLineWithoutANameAfterTheDateIsNoEntry() {
        #expect(list("-rw-r--r-- 1 u g 5 Jan 01 2020") == nil)
        #expect(list("-rw-r--r-- 1 u g 5 2024-01-31 12:34") == nil)
    }

    /// Clock times that are no time make the line no entry.
    @Test
    internal func clockTimesThatAreNoTimeMakeTheLineNoEntry() {
        // A fraction without digits, and an hour or a second of three digits.
        #expect(list("-rw-r--r-- 1 u g 5 2024-01-31 12:34. name") == nil)
        #expect(list("-rw-r--r-- 1 u g 5 2024-01-31 12:34.5x name") == nil)
        #expect(list("-rw-r--r-- 1 u g 5 2024-01-31 123:34 name") == nil)
        #expect(list("-rw-r--r-- 1 u g 5 2024-01-31 12:34:567 name") == nil)
        #expect(list("-rw-r--r-- 1 u g 5 2024-01-31 12:34:56.789 name")?.modified == date(2_024, 1, 31, 12, 34))
    }

    /// A time zone after the time is skipped in either direction.
    @Test
    internal func aTimeZoneAfterTheTimeIsSkippedInEitherDirection() {
        #expect(list("-rw-r--r-- 1 u g 5 2024-01-31 12:34 -0500 west")?.name == "west")
        #expect(list("-rw-r--r-- 1 u g 5 2024-01-31 12:34 +0100 east")?.name == "east")
    }

    /// A recent date with an impossible hour has no date.
    @Test
    internal func aRecentDateWithAnImpossibleHourHasNoDate() throws {
        let entry = try #require(list("-rw-r--r-- 1 u g 5 Jan 01 99:00 late"))
        #expect(entry.name == "late" && entry.modified == nil)
    }

    /// DOS listings take slashes and full stops between the date parts.
    @Test
    internal func dosListingsTakeSlashesAndFullStopsBetweenTheDateParts() {
        #expect(list("01/31/24  03:04PM       12 slash.txt")?.modified == date(2_024, 1, 31, 15, 4))
        #expect(list("01.31.2024  15:04  1,234 dots.txt")?.size == 1_234)
        #expect(list("01-31-24  03:04pm  7 lower.txt")?.modified == date(2_024, 1, 31, 15, 4))
    }

    /// DOS lines that break off are no entry.
    @Test
    internal func dosLinesThatBreakOffAreNoEntry() {
        // Another separator, a minute of one digit, no gap after the time, a kind without its end.
        #expect(list("01x31-24  03:04PM  7 a") == nil)
        #expect(list("01-31-24  03:4PM  7 a") == nil)
        #expect(list("01-31-24  03:04X  7 a") == nil)
        #expect(list("01-31-24  03:04PM  <DIR name") == nil)
    }

    /// EPLF needs a tab and skips empty facts.
    @Test
    internal func eplfNeedsATabAndSkipsEmptyFacts() {
        #expect(list("+i1,s5,m0") == nil)
        let entry = list("+,,s5,m0,\tfile")
        #expect(entry?.name == "file" && entry?.size == 5 && entry?.modified == Date(timeIntervalSince1970: 0))
    }

    /// A date outside the calendar is no date.
    @Test
    internal func aDateOutsideTheCalendarIsNoDate() {
        var parts = DateComponents()
        (parts.year, parts.month, parts.day) = (2_024, 13, 1)
        #expect(FTPListParser.date(parts, calendar: Self.utc) == nil)
        (parts.month, parts.day) = (1, 32)
        #expect(FTPListParser.date(parts, calendar: Self.utc) == nil)
        parts.day = nil
        #expect(FTPListParser.date(parts, calendar: Self.utc) == nil)
    }
}
