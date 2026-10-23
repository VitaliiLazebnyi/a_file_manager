import AFMKernel
import Foundation
import Testing

@testable import MultiRenamePlugin

/// The placeholder language, Search & Replace, the case conversions and the planner of the
/// Multi-Rename Tool, without any file system.
@Suite
internal struct MultiRenameEngine {
    /// 2025-12-01 10:05:09.250 UTC.
    internal static let date = Date(timeIntervalSince1970: 1_764_583_509.25)

    /// What the masks get: twelve items, UTC, the POSIX locale, two environment variables, and the
    /// moments the tool was opened and its options changed.
    internal var context: RenameContext = {
        var made = RenameContext()
        made.count = 12
        made.timeZone = TimeZone(identifier: "UTC") ?? .current
        made.locale = Locale(identifier: "en_US_POSIX")
        made.environment = ["USER": "ada", "WORK": "/Users/ada/Work:Files"]
        made.opened = Date(timeIntervalSince1970: 86_400 * 366)
        made.changed = Date(timeIntervalSince1970: 86_400 * 731)
        return made
    }()

    /// The item most tests rename: a picture in `/Users/ada/work/photos`.
    internal let photo = RenameSubject(
        name: "IMG_1001.jpg",
        isFolder: false,
        size: 4_711,
        modified: Self.date,
        directoryPath: "/Users/ada/work/photos",
        folders: RenameSubject.folders(in: "/Users/ada/work/photos"),
        url: nil
    )

    /// Leaves the settings as they are.
    internal static func asTheyAre(_: inout RenameSettings) {
        // Nothing is changed.
    }

    /// The settings with the masks `mask` and `ext`, changed by `change`.
    internal static func settings(
        _ mask: String,
        ext: String,
        _ change: (inout RenameSettings) -> Void
    ) -> RenameSettings {
        var settings = RenameSettings()
        settings.nameMask = mask
        settings.extensionMask = ext
        change(&settings)
        return settings
    }

    /// The new name `settings` give `subject` at `index` in `context`.
    internal func evaluated(
        _ settings: RenameSettings,
        subject: RenameSubject,
        index: Int,
        context: RenameContext
    ) -> String? {
        RenameEngine(settings, context: context).newName(for: subject, index: index)
    }

    /// The new name of the photo with the masks `mask` and `ext`.
    internal func name(_ mask: String, ext: String) -> String? {
        evaluated(Self.settings(mask, ext: ext, Self.asTheyAre), subject: photo, index: 0, context: context)
    }

    /// The new name of `subject` with the masks `mask` and `ext`.
    internal func name(_ mask: String, ext: String, _ subject: RenameSubject) -> String? {
        evaluated(Self.settings(mask, ext: ext, Self.asTheyAre), subject: subject, index: 0, context: context)
    }

    /// The new name of the photo with the masks `mask` and `ext`, the settings changed by `change` first.
    internal func name(_ mask: String, ext: String, _ change: (inout RenameSettings) -> Void) -> String? {
        evaluated(Self.settings(mask, ext: ext, change), subject: photo, index: 0, context: context)
    }

    /// The new name of the photo at `index` with the masks `mask` and `ext`, the settings changed by `change`.
    internal func name(
        _ mask: String,
        ext: String,
        index: Int,
        _ change: (inout RenameSettings) -> Void
    ) -> String? {
        evaluated(Self.settings(mask, ext: ext, change), subject: photo, index: index, context: context)
    }

    /// The name mask alone, without an extension, for the photo.
    internal func part(_ mask: String) -> String? {
        name(mask, ext: "")
    }

    /// The name mask alone, without an extension, for `subject`.
    internal func part(_ mask: String, _ subject: RenameSubject) -> String? {
        name(mask, ext: "", subject)
    }

    /// The name mask alone, without an extension, for the photo at `index`.
    internal func part(_ mask: String, index: Int) -> String? {
        evaluated(Self.settings(mask, ext: "", Self.asTheyAre), subject: photo, index: index, context: context)
    }

    /// The name mask alone, without an extension, for the photo in `context`.
    internal func part(_ mask: String, context: RenameContext) -> String? {
        evaluated(Self.settings(mask, ext: "", Self.asTheyAre), subject: photo, index: 0, context: context)
    }

    // MARK: Masks

    /// Text outside the brackets stays, `[[]` and `[]]` are brackets, and the plain placeholders give the
    /// parts of the name.
    @Test
    internal func literalsAndBrackets() {
        #expect(name("[N]", ext: "[E]") == "IMG_1001.jpg")
        #expect(part("Photo") == "Photo")
        #expect(part("a[[]b[]]c") == "a[b]c")
        #expect(part("[N][E]") == "IMG_1001jpg")
        #expect(name("[N]", ext: "") == "IMG_1001")
        #expect(name("x", ext: "[E]") == "x.jpg")
        #expect(part("[A]") == "IMG_1001.jpg")
        #expect(part("[S]") == "4711")
    }

    /// A placeholder that cannot be read gives no name, and the mask says what is wrong.
    @Test
    internal func invalidPlaceholdersGiveAnError() {
        #expect(part("[Q]") == nil)
        #expect(part("[N") == nil)
        #expect(part("[]") == nil)
        #expect(part("[N0]") == nil)
        #expect(part("[T9]") == nil)
        #expect(part("[=tc.size]") == nil)
        #expect(RenameMask("[=tc.size]").error == .contentPluginsUnavailable)
        #expect(RenameMask("[N][Q]").error == .invalidPlaceholder("[Q]"))
        #expect(RenameMask("[N] [C10+5:3]").error == nil)
    }

    /// The range forms take the characters they say from the name.
    @Test(arguments: [
        ("[N1]", "a"), ("[N-5]", "e"), ("[N2-5]", "bcde"), ("[N2,5]", "bcdef"), ("[N2-]", "bcdefghi"),
        ("[N-8,5]", "bcdef"), ("[N-8-5]", "bcde"), ("[N2--5]", "bcde"), ("[N-5-]", "efghi"), ("[N20-]", ""),
        ("[N7-20]", "ghi"), ("[N-20-2]", "abcdefgh")
    ])
    internal func ranges(mask: String, expected: String) {
        #expect(part(mask, RenameSubject(name: "abcdefghi.txt")) == expected)
    }

    /// A range with a `0` or a space in front is filled to its width.
    @Test
    internal func rangePadding() {
        let short = RenameSubject(name: "abc.txt")
        #expect(part("[N02-9]", short) == "000000bc")
        #expect(part("[N 2-9]", short) == "      bc")
        #expect(part("[N02,4]", short) == "00bc")
        #expect(part("[E1-2]", short) == "tx")
        #expect(part("[A5-]", short) == "txt")
    }

    /// Ranges count characters, not bytes.
    @Test
    internal func rangesCountCharactersNotBytes() {
        #expect(part("[N2-3]", RenameSubject(name: "a😀éz.txt")) == "😀é")
    }

    /// The parent, grandparent and numbered folders, and ranges of the full path.
    @Test
    internal func pathParts() {
        #expect(part("[P]") == "photos")
        #expect(part("[G]") == "work")
        #expect(part("[P1-3]") == "pho")
        #expect(part("[B0]-[B1]-[B2]-[B9]") == "photos-work-ada-")
        #expect(part("[B+1]-[B+2]-[B+0]") == "Users-ada-")
        #expect(part("[B1_1-2]") == "wo")
        #expect(part("[2-6]") == "Users")
        #expect(part("[-12-]") == "IMG_1001.jpg")
    }

    /// The dot of a folder starts an extension unless `[I]` is on, which `[I0]` and a second `[I]` turn off.
    @Test
    internal func foldersAndTheFolderDotSwitch() {
        let folder = RenameSubject(
            name: "release.v2",
            isFolder: true,
            size: 0,
            modified: Date(timeIntervalSince1970: 0),
            directoryPath: "",
            folders: [],
            url: nil
        )
        #expect(name("[N]", ext: "[E]", folder) == "release.v2")
        #expect(name("[N]_x", ext: "[E]", folder) == "release_x.v2")
        #expect(name("[I][N]_x", ext: "[E]", folder) == "release.v2_x")
        #expect(name("[I][N]_x", ext: "[E]") == "IMG_1001_x.jpg")
        #expect(name("[I][I0][N]_x", ext: "[E]", folder) == "release_x.v2")
        #expect(name("[I][I][N]_x", ext: "[E]", folder) == "release_x.v2")
        #expect(part("[N]", RenameSubject(name: ".zshrc")) == ".zshrc")
    }

    /// The counters written into the placeholder: start, step, width, divisor and letters.
    @Test
    internal func counters() {
        #expect((0..<3).map { part("[C]", index: $0) } == ["1", "2", "3"])
        #expect((0..<3).map { part("[C10+5:3]", index: $0) } == ["010", "015", "020"])
        #expect(part("[C10]", index: 2) == "12")
        #expect(part("[C+5]", index: 2) == "11")
        #expect(part("[C:3]", index: 2) == "003")
        #expect(part("[C:a]", index: 2) == "03")
        #expect(part("[C10+10:a]", index: 1) == "20")
        #expect(part("[C5-2]", index: 4) == "-3")
        #expect([0, 99, 100, 250].map { part("[C+1/100]", index: $0) } == ["1", "1", "2", "3"])
        #expect([0, 1, 25, 26].map { part("[Caa+1]", index: $0) } == ["aa", "ab", "az", "ba"])
        #expect(part("[CA+2]", index: 3) == "G")
        #expect(part("File [C] of [c]", index: 4) == "File 5 of 12")
    }

    /// The counter of "Define counter" and the counts `[c2]` and `[c3]`; an inline counter ignores it.
    @Test
    internal func definedCounter() {
        func counted(_ mask: String, _ counter: CounterDefinition, index: Int) -> String? {
            name(mask, ext: "", index: index) { $0.counter = counter }
        }
        let definition = CounterDefinition(start: 110, step: 15, digits: 1)
        #expect(
            (0..<2).map { counted("Photo_[C]_[Y]-[M]-[D]", definition, index: $0) } == [
                "Photo_110_2025-12-01", "Photo_125_2025-12-01"
            ]
        )
        #expect(counted("[C]", CounterDefinition(start: 1, step: 1, digits: 4), index: 6) == "0007")
        #expect(counted("[C]", CounterDefinition(start: 5, step: -2, digits: 2), index: 4) == "-03")
        #expect(counted("[C]", CounterDefinition(start: 1, step: 1, digits: 0), index: 0) == "01")
        #expect(counted("[c2]", CounterDefinition(start: 1, step: 1, digits: 4), index: 0) == "0012")
        #expect(counted("[c3]", definition, index: 0) == "275")
        // An inline definition ignores the fields.
        #expect(counted("[C3]", definition, index: 1) == "4")
    }

    /// The date and time fields of the date changed, in two digits and the regional formats.
    @Test
    internal func dateAndTime() {
        #expect(part("[YMD]_[hms]") == "20251201_100509")
        #expect(part("[Y]-[M]-[D] [h].[m].[s].[v]") == "2025-12-01 10.05.09.250")
        #expect(part("[y][H][i][i1]") == "2510ama")
        #expect(part("[d]") == "12-1-25")
        #expect(part("[t]") == "10.05.09 AM")
        let evening = RenameSubject(
            name: "a",
            isFolder: false,
            size: 0,
            modified: Self.date.addingTimeInterval(3 * 3_600),
            directoryPath: "",
            folders: [],
            url: nil
        )
        #expect(part("[h]-[H]-[i]", evening) == "13-01-pm")
        #expect(part("[H]", RenameSubject(name: "a")) == "12")
    }

    /// The time sources and offsets hold from their place on, also in the extension mask.
    @Test
    internal func timeSourcesAndOffsets() {
        #expect(part("[T2][Y]") == "1971")
        #expect(part("[Y][T3][Y][T1][Y]") == "202519722025")
        #expect(part("[T1+60m][hms]") == "110509")
        #expect(part("[T1-11h][YMD][h]") == "2025113023")
        #expect(part("[T1+1M][YMD]") == "20260101")
        #expect(part("[T1+1D][D][T1-1Y][Y][T1+51s][m][s]") == "0220240600")
        // The switch of the name mask still holds in the extension mask.
        #expect(name("[T2]x", ext: "[Y]") == "x.1971")
        #expect(part("[T4][Y]") == nil)
        var context = self.context
        context.contentDate = { _ in Date(timeIntervalSince1970: 0) }
        #expect(part("[T4][Y]", context: context) == "1970")
    }

    /// The case switches convert what follows them, words found across the pieces of one run.
    @Test
    internal func caseSwitches() {
        let subject = RenameSubject(name: "my Holiday PICS.JPG")
        #expect(part("[U][N]", subject) == "MY HOLIDAY PICS")
        #expect(part("[L][N]", subject) == "my holiday pics")
        #expect(part("[F][N]", subject) == "My Holiday Pics")
        #expect(part("[U][N1-2][n][N3-]", subject) == "MY Holiday PICS")
        #expect(part("[U]abc[L]DEF[n]Ghi", subject) == "ABCdefGhi")
        #expect(name("[U][N]", ext: "[E]", subject) == "MY HOLIDAY PICS.JPG")
        #expect(name("[N]", ext: "[L][E]", subject) == "my Holiday PICS.jpg")
        #expect(part("[f][N]", RenameSubject(name: "the lord OF the rings")) == "The Lord of the Rings")
        // Words are found across the pieces of one run.
        #expect(part("[F]great [N]", RenameSubject(name: "dane")) == "Great Dane")
        // Compared by scalars: Swift calls the precomposed and the decomposed letter equal.
        #expect(part("[u][N]", RenameSubject(name: "a\u{302}"))?.unicodeScalars.map(\.value) == [0xE2])
    }

    /// Environment variables in their forms, and the first line of the clipboard made fit for a name.
    @Test
    internal func environmentAndClipboard() {
        #expect(part("[%USER%]") == "ada")
        #expect(part("[%USER%1-2]") == "ad")
        #expect(part("[%WORK%/]") == "Work:Files")
        #expect(part("[%WORK%_]") == "_Users_ada_WorkFiles")
        #expect(part("[%MISSING%]x") == "x")
        #expect(part("[%USER]") == nil)
        #expect(part("[X]") == nil)
        #expect(part("[X+]x") == "x")
        var context = self.context
        context.clipboard = "a*b?c:d/e\nsecond line"
        #expect(part("[X]", context: context) == "a_b_c_d_e")
        #expect(part("[X2-3]", context: context) == "_b")
    }
}
