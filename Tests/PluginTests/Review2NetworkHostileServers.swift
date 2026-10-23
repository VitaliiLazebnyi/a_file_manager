import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// What a server sends is read in time that grows with its length and nothing else, and is
/// taken only as far as it makes sense (review 2: N001, N004, N023, N024, N025, N074, N155).
@Suite
internal struct Review2NetworkHostileServers {
    /// The listing line that made the old patterns backtrack for minutes is read at once, as are the worst lines.
    @Test
    internal func theLineThatMadeTheListingHangIsReadAtOnce() throws {
        let line = try NetworkReproducers.text("ftplist-regex-backtracking.txt")
        // With the patterns it was read with before, each of these took seconds (one of 16 KB a
        // minute). Two hundred of them, and of the worst that fit into a line, are nothing now.
        let digits = "-rwxrwxrwx " + String(repeating: "9", count: FTPListParser.longestLine - 11)
        let spaces = "01-01-24  03:04" + String(repeating: " ", count: FTPListParser.longestLine - 20) + "x"
        let started = Date()
        for _ in 0..<200 {
            _ = FTPListParser.list(line)
            #expect(FTPListParser.list(digits) == nil)
            #expect(FTPListParser.list(spaces) == nil)
        }
        #expect(Date().timeIntervalSince(started) < 30)
    }

    /// A line longer than the longest line is no entry, in LIST and MLSD alike.
    @Test
    internal func aLineThatIsTooLongIsNoEntry() {
        let name = String(repeating: "n", count: FTPListParser.longestLine)
        #expect(FTPListParser.list("-rw-r--r-- 1 o g 5 Jan 01 2020 " + name) == nil)
        #expect(FTPListParser.mlsd("type=file;size=5; " + name) == nil)
        #expect(FTPListParser.list("-rw-r--r-- 1 o g 5 Jan 01 2020 " + String(name.prefix(200)))?.name.count == 200)
    }

    /// UNIX, NetWare and Windows lines in their many forms are still read, and lines that are no entry are not.
    @Test
    internal func theFormatsAreStillRead() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(calendar.date(from: DateComponents(year: 2_024, month: 6, day: 15)))
        func list(_ line: String) -> RemoteEntry? { FTPListParser.list(line, now: now, calendar: calendar) }
        func day(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date? {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
        }
        var entry = try #require(list("-rw-r--r--   1 owner    group        1234 Jan 31  2024 a file  with spaces.txt"))
        #expect(
            entry.name == "a file  with spaces.txt" && entry.size == 1_234 && entry.modified == day(2_024, 1, 31)
                && entry.permissions == 0o644
        )
        // The time instead of the year means the last months; a date ahead of today is last year's.
        #expect(list("-rw-r--r-- 1 o g 7 Mar  5 12:30 r.txt")?.modified == day(2_024, 3, 5, 12, 30))
        #expect(list("-rw-r--r-- 1 o g 7 Dec 24 08:00 r.txt")?.modified == day(2_023, 12, 24, 8, 0))
        // No group, device numbers, a name that starts with a space, a link.
        #expect(list("drwxr-xr-x 2 owner 4096 Feb 29 2024 dir")?.isDirectory == true)
        entry = try #require(list("crw-rw-rw- 1 root wheel 3, 2 Jan  1  2020 null"))
        #expect(entry.name == "null" && entry.size == 2 && entry.isSpecial)
        #expect(list("-rw-r--r-- 1 o g 5 Jan 01 2020  lead")?.name == " lead")
        entry = try #require(list("lrwxrwxrwx 1 o g 9 Jan 01 2020 link -> /some/where"))
        #expect(entry.name == "link" && entry.linkTarget == "/some/where" && entry.isSymlink)
        // The day before the month, other languages, ISO dates with and without a zone, NetWare.
        #expect(list("-rw-r--r-- 1 o g 5 31. Jan 2024 e.txt")?.modified == day(2_024, 1, 31))
        #expect(list("-rw-r--r-- 1 o g 5 déc. 24 2023 f.txt")?.modified == day(2_023, 12, 24))
        #expect(list("-rw-r--r-- 1 o g 5 2024-01-31 12:34 iso.txt")?.modified == day(2_024, 1, 31, 12, 34))
        entry = try #require(list("-rw-r--r-- 1 o g 5 2024-01-31 12:34:56.789 +0100 zone.txt"))
        #expect(entry.name == "zone.txt" && entry.size == 5)
        #expect(list("-rw-r--r-- 1 o g 5 2024-01-31 12:34 +0100")?.name == "+0100")
        #expect(list("d [RWCEAFMS] owner 512 Jan 16 18:53 login")?.isDirectory == true)
        // A name that looks like a date does not move the date.
        #expect(list("-rw-r--r-- 1 o g 5 Jan 01 2020 Feb 02 2021 x")?.name == "Feb 02 2021 x")
        // Windows.
        entry = try #require(list("01-31-24  03:04PM              1,234 report final.doc"))
        #expect(entry.name == "report final.doc" && entry.size == 1_234 && entry.modified == day(2_024, 1, 31, 15, 4))
        #expect(list("01-31-2024  15:04       <DIR>          Program Files")?.isDirectory == true)
        #expect(list("12-01-99  12:05AM  7 old.txt")?.modified == day(1_999, 12, 1, 0, 5))
        #expect(list("01-31-24  03:04PM       <NOPE>         x") == nil && list("01-31-24  03:04PM 12") == nil)
        // Lines that are no entry.
        for line in [
            "total 12", "", "-rw-r--r-- 1 o g 5 Jan 01 2020 .", "-rw-r--r-- 1 o g 5 Jan 41 2020 x",
            "-rw-r--r-- 1 o g Jan 01 2020"
        ] {
            #expect(list(line) == nil, "\(line)")
        }
    }

    /// Sizes too large to hold are the largest size; dates that are none are no date.
    @Test
    internal func sizesAndDatesAreTakenAsFarAsTheyMakeSense() {
        let huge = String(repeating: "9", count: 40)
        #expect(FTPListParser.list("-rw-r--r-- 1 o g \(huge) Jan 01 2020 big")?.size == .max)
        #expect(FTPListParser.mlsd("type=file;size=\(huge); big")?.size == .max)
        #expect(FTPListParser.mlsd("type=file;size=-5; neg")?.size == 0)
        #expect(FTPListParser.mlsd("type=file;size=abc; odd")?.size == 0)
        #expect(FTPListParser.list("+s\(huge),\tbig")?.size == .max)
        #expect(FTPListParser.list("01-31-24  03:04PM  \(huge) big")?.size == .max)
        // Dates that are none give no date, and no trap.
        #expect(FTPListParser.list("+m1e300,\tx")?.modified == nil)
        #expect(FTPListParser.list("+m-5,\tx")?.modified == nil)
        #expect(FTPListParser.list("+m\(huge),\tx")?.modified == nil)
        #expect(FTPListParser.list("+m824255902,\tx")?.modified == Date(timeIntervalSince1970: 824_255_902))
        #expect(FTPListParser.list("-rw-r--r-- 1 o g 5 Jan 01 0000 x")?.modified == nil)
        #expect(FTPListParser.list("-rw-r--r-- 1 o g 5 2024-13-45 99:99 x")?.modified == nil)
        #expect(FTPListParser.mlsd("type=file;modify=00000000000000; x")?.modified == nil)
        #expect(FTPSyntax.time("99999999999999") == nil)
        #expect(FTPListParser.list("+up7777777,\tx")?.permissions == nil)
    }

    /// A listing is cut into lines the same whatever its blocks, and a line too long is dropped as it comes.
    @Test
    internal func aListingIsCutIntoLinesByteByByteOnce() {
        let text = "one\r\ntwo\n\nlast without end"
        let firstLines = ["one", "two", ""].map { Data($0.utf8) }
        var whole = LineSplitter(limit: FTPLimits.lineLength)
        #expect(whole.feed(Data(text.utf8)) == firstLines)
        #expect(whole.finish() == Data("last without end".utf8))
        // The same, whatever the sizes of the blocks.
        var bytewise = LineSplitter(limit: FTPLimits.lineLength)
        var lines: [Data] = []
        for byte in Data(text.utf8) { lines += bytewise.feed(Data([byte])) }
        #expect(lines == firstLines)
        #expect(bytewise.finish() == Data("last without end".utf8))

        // A megabyte without a line end is dropped as it comes; what follows it is read.
        var hostile = LineSplitter(limit: FTPLimits.lineLength)
        for _ in 0..<1_024 { #expect(hostile.feed(Data(repeating: 0x39, count: 1_024)).isEmpty) }
        #expect(hostile.feed(Data("\nfine\n".utf8)) == [Data("fine".utf8)])
        #expect(hostile.dropped == 1 && hostile.finish() == nil)
        // The longest line that is kept, and one byte more.
        var edge = LineSplitter(limit: FTPLimits.lineLength)
        #expect(
            edge.feed(Data(repeating: 0x61, count: FTPLimits.lineLength) + Data("\r\n".utf8)).first?.count
                == FTPLimits.lineLength
        )
        #expect(
            edge.feed(Data(repeating: 0x61, count: FTPLimits.lineLength + 2) + Data("\n".utf8)).isEmpty
                && edge.dropped == 1
        )
    }

    /// A reply of very many lines is kept only up to its largest size, and the next reply starts clean.
    @Test
    internal func aReplyIsKeptOnlyUpToItsLargestSize() {
        var parser = FTPReplyParser()
        #expect(parser.feed("220-Welcome") == nil)
        for index in 0..<50_000 { #expect(parser.feed(" line \(index) " + String(repeating: "x", count: 100)) == nil) }
        #expect(parser.linesOfOpenReply == 50_001)
        let reply = parser.feed("220 Ready")
        #expect(reply?.code == 220 && reply?.lines.last == "Ready" && reply?.lines.first == "Welcome")
        #expect((reply?.lines.count ?? .max) <= FTPLimits.replyLines + 1)
        #expect((reply?.lines.reduce(0) { $0 + $1.utf8.count } ?? .max) <= FTPLimits.replyBytes + FTPLimits.lineLength)
        // The parser starts clean for the next reply.
        #expect(parser.feed("200 OK") == FTPReply(code: 200, lines: ["OK"]) && parser.linesOfOpenReply == 0)
    }
}
