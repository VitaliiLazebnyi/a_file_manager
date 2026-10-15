import AFMKernel
import Foundation
import Testing

@testable import FilePropertiesPlugin

/// The pure parts of the file-properties plugin: the comment file format, permission and date
/// entries, command parameters, link paths and the wording of the space report.
@Suite
internal struct FilePropertiesFormats {
    /// A calendar in UTC, so that dates read the same on every machine.
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    // MARK: descript.ion

    /// A comment file as Total Commander writes it reads back, and is written back byte for byte.
    @Test
    internal func readsTheCommentFileAsTotalCommanderWritesIt() {
        // ANSI with ü = 0xFC, a multi-line comment with its marker bytes, a quoted name.
        var bytes = Data("sel.txt Selection list ".utf8) + Data([0xFC, 0x0D, 0x0A])
        bytes += Data("ro.txt first line\\nsecond line".utf8) + Data([0x04, 0xC2, 0x0D, 0x0A])
        bytes += Data("\"long name.txt\" Comment of a name with spaces\r\n".utf8)
        let file = DescriptIon(data: bytes)
        #expect(file.encoding == .ansi)
        #expect(file.comment(for: "sel.txt") == "Selection list ü")
        #expect(file.comment(for: "RO.TXT") == "first line\nsecond line")
        #expect(file.comment(for: "long name.txt") == "Comment of a name with spaces")
        #expect(file.comment(for: "other.txt") == nil)
        // Written back, the bytes are the same.
        #expect(file.data() == bytes)
    }

    /// Comments change in place, new ones go to the end, and empty ones are removed.
    @Test
    internal func changesCommentsAndKeepsTheOrder() {
        var file = DescriptIon(data: Data("a.txt one\r\nb.txt two\r\n".utf8))
        file.setComment("changed", for: "A.TXT")
        file.setComment("new\r\nlines \n", for: "my file")
        file.setComment("", for: "b.txt")
        file.setComment("", for: "missing")
        #expect(file.entries.map(\.name) == ["a.txt", "my file"])
        #expect(
            String(data: file.data(), encoding: .windowsCP1252)
                == "a.txt changed\r\n\"my file\" new\\nlines\u{04}\u{C2}\r\n"
        )
        file.setComment("", for: "a.txt")
        file.setComment("", for: "my file")
        #expect(file.isEmpty)
    }

    /// The file is written in the code page when it can be, in UTF-16 when not, and UTF-8 stays UTF-8.
    @Test
    internal func choosesAnEncodingThatHoldsEveryCharacter() {
        var plain = DescriptIon()
        plain.setComment("größer", for: "a.txt")
        #expect(plain.data() == "a.txt größer\r\n".data(using: .windowsCP1252))
        // Outside the code page: UTF-16 LE with a byte-order mark.
        plain.setComment("日本語", for: "b.txt")
        let wide = plain.data()
        #expect(wide.starts(with: [0xFF, 0xFE]))
        let again = DescriptIon(data: wide)
        #expect(
            again.encoding == .utf16LittleEndian && again.comment(for: "b.txt") == "日本語"
                && again.comment(for: "a.txt") == "größer"
        )
        // A UTF-8 file stays UTF-8, with or without its mark.
        let utf8 = DescriptIon(data: Data([0xEF, 0xBB, 0xBF]) + Data("a.txt größer\r\n".utf8))
        #expect(
            utf8.encoding == .utf8(bom: true) && utf8.comment(for: "a.txt") == "größer"
                && utf8.data().starts(with: [0xEF, 0xBB, 0xBF])
        )
        #expect(DescriptIon(data: Data("a.txt größer\n".utf8)).encoding == .utf8(bom: false))
        #expect(DescriptIon(data: Data([0xFE, 0xFF, 0x00, 0x61, 0x00, 0x20, 0x00, 0x62])).comment(for: "a") == "b")
    }

    // MARK: Permissions

    /// Octal, symbolic and `chmod`-style changes are read; anything else is refused.
    @Test
    internal func readsPermissionsInEveryNotation() {
        #expect(PermissionChange("") == .unchanged && PermissionChange("  ") == .unchanged)
        // An octal mode is the whole mode, as for `chmod` (review 2, F028): three digits clear the special bits.
        #expect(PermissionChange("755")?.applied(to: 0o4600, isDirectory: false) == 0o755)
        #expect(PermissionChange("0755")?.applied(to: 0o4600, isDirectory: false) == 0o755)
        #expect(PermissionChange("rw-r-----")?.applied(to: 0o777, isDirectory: false) == 0o640)
        #expect(PermissionChange("u+x,go-w")?.applied(to: 0o666, isDirectory: false) == 0o744)
        #expect(PermissionChange("+x")?.applied(to: 0o644, isDirectory: false) == 0o755)
        #expect(PermissionChange("go=r")?.applied(to: 0o777, isDirectory: false) == 0o744)
        #expect(PermissionChange("a-w")?.applied(to: 0o666, isDirectory: false) == 0o444)
        // X: execute for folders and for files someone may already execute.
        #expect(PermissionChange("a+X")?.applied(to: 0o644, isDirectory: false) == 0o644)
        #expect(PermissionChange("a+X")?.applied(to: 0o644, isDirectory: true) == 0o755)
        #expect(PermissionChange("a+X")?.applied(to: 0o744, isDirectory: false) == 0o755)
        for wrong in ["9", "75", "888", "rwxrwxrw", "rwxrwxrwz", "u+q", "z+r", "u"] {
            #expect(PermissionChange(wrong) == nil, "\(wrong)")
        }
    }

    // MARK: Date and time

    /// Letters in a date or time keep that part of the original; seconds left out become 0.
    @Test
    internal func partialDatesKeepTheOtherParts() throws {
        let original = try #require(
            utc.date(from: DateComponents(year: 2_026, month: 10, day: 11, hour: 9, minute: 58, second: 52))
        )
        func change(_ date: String, _ time: String) -> String? {
            guard let new = TimestampChange(date: date, time: time)?.applied(to: original, now: Date(), calendar: utc)
            else { return nil }
            let texts = TimestampChange.fieldTexts(for: new, calendar: utc)
            return texts.date + " " + texts.time
        }
        #expect(change("2020-01-02", "03:04:05") == "2020-01-02 03:04:05")
        #expect(change("yyyy-05-dd", "hh:mm:ss") == "2026-05-11 09:58:52")
        #expect(change("aaaa.05.aa", "xy.10.xy") == "2026-05-11 09:10:52")
        // Seconds left out become 0; an empty field keeps everything of its half.
        #expect(change("", "12:30") == "2026-10-11 12:30:00")
        #expect(change("2021/2/3", "") == "2021-02-03 09:58:52")
        #expect(change("2021-02-31", "") == nil)
        #expect(
            TimestampChange(date: "2021-13-01", time: "") == nil && TimestampChange(date: "2021-01", time: "") == nil
        )
        #expect(TimestampChange(date: "", time: "25:00") == nil && TimestampChange(date: "x-1-y", time: "") != nil)
        #expect(TimestampChange(date: "", time: "")?.changesNothing == true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(TimestampChange.current.applied(to: original, now: now) == now)
    }

    /// The parameters of the command read as Total Commander's; wrong ones are refused.
    @Test
    internal func readsCommandParameters() throws {
        let parsed = try #require(AttributeChange.parse(parameters: "= +h -r +f +m640 +a -s +d2020-01-02 +t03:04"))
        #expect(
            parsed.applyAtOnce && parsed.change.hidden == true && parsed.change.locked == false && parsed.change.recurse
        )
        #expect(parsed.change.permissions == .absolute(0o640, keepingSpecialBits: false))
        #expect(parsed.change.timestamp?.parts == [2_020, 1, 2, 3, 4, 0])
        let dialog = try #require(AttributeChange.parse(parameters: "-h +mu+x"))
        #expect(!dialog.applyAtOnce && dialog.change.hidden == false && dialog.change.timestamp == nil)
        // `+c +t`: the current date, and the time as it is.
        let dateOnly = try #require(AttributeChange.parse(parameters: "=+c +t"))
        #expect(
            dateOnly.applyAtOnce && dateOnly.change.timestamp?.parts[0] != nil
                && dateOnly.change.timestamp?.parts[3] == nil
        )
        #expect(AttributeChange.parse(parameters: "+q") == nil && AttributeChange.parse(parameters: "h") == nil)
        #expect(AttributeChange.parse(parameters: "+m999") == nil && AttributeChange.parse(parameters: "+d2020") == nil)
        #expect(AttributeChange.parse(parameters: "")?.change.isEmpty == true)
    }

    // MARK: Links and reports

    /// A relative link path climbs out of the link's folder as far as needed.
    @Test
    internal func relativeLinkPaths() {
        func path(_ source: String, _ target: String) -> String {
            LinkMaker.relativePath(
                from: URL(fileURLWithPath: source, isDirectory: true),
                to: URL(fileURLWithPath: target)
            )
        }
        #expect(path("/a/b", "/a/b/file.txt") == "file.txt")
        #expect(path("/a/b", "/a/c/file.txt") == "../c/file.txt")
        #expect(path("/a/b/c", "/x") == "../../../x")
        #expect(path("/a/b", "/a/b") == ".")
    }

    /// The space report reads as Total Commander's, with the parts that apply.
    @Test
    internal func spaceReportWording() {
        let small = SpaceReport.text(
            SpaceTotals(bytes: 23, allocated: 4_096, rounded: 4_096, files: 1),
            sourceIsLocal: true,
            targetCluster: 4_096,
            volume: VolumeInfo(name: "Disk", freeBytes: 2_048 * 1_024, totalBytes: 4_096 * 1_024),
            cancelled: false
        )
        #expect(
            small == """
                23 bytes in 1 file(s)

                Actual space used on source volume: 4,096 bytes
                Required on target volume: 4,096 bytes

                Disk: 2,048 k of 4,096 k free
                """
        )
        let large = SpaceReport.text(
            SpaceTotals(bytes: 23_332_990, files: 101, folders: 14, unreadable: 1),
            sourceIsLocal: false,
            targetCluster: nil,
            volume: nil,
            cancelled: true
        )
        #expect(large.hasPrefix("23,332,990 bytes in 101 file(s),\nin 14 directories\n(= 22,786 k, 22.25 M)"))
        #expect(
            large.contains("1 folder(s) could not be read") && large.contains("stopped")
                && !large.contains("Actual space")
        )
        #expect(
            SpaceCalculator.round(1, to: 4_096) == 4_096 && SpaceCalculator.round(4_096, to: 4_096) == 4_096
                && SpaceCalculator.round(0, to: 4_096) == 0
        )
        #expect(SpaceCalculator.round(5, to: nil) == 5)
    }
}
