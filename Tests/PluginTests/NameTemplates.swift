import FileOperationsPlugin
import Foundation
import Testing

/// The names of new folders and files: lists, placeholders, counters (spec 07 › New folder, 18 › Placeholders).
@Suite
internal struct NameTemplates {
    /// 2026-10-12 14:03:07.250 UTC, cursor on `Holiday pics.jpeg` in /Volumes/Data/Photos.
    internal var context: NameTemplate.Context {
        var fixed = NameTemplate.Context()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        fixed.calendar = calendar
        fixed.now = Date(timeIntervalSince1970: 1_791_813_787.25)
        fixed.cursorName = "Holiday pics.jpeg"
        fixed.cursorSize = 4_096
        fixed.parentName = "Photos"
        fixed.grandparentName = "Data"
        fixed.clipboard = "from: the *clipboard*\nsecond line"
        fixed.environment = ["USER": "ada", "LONG": "abcdefgh"]
        return fixed
    }

    /// The names `text` stands for in the fixed context; `quoted` reads lists of names in quotes.
    private func names(_ text: String, quoted: Bool = false) throws -> [String] {
        try NameTemplate.names(from: text, context: context, quotedLists: quoted)
    }

    /// Plain names, lists split at `|` and quoted names come back as typed, nested paths included.
    @Test
    internal func plainNamesListsAndNesting() throws {
        #expect(try names("docs") == ["docs"])
        #expect(try names(" made/inner | other ||") == ["made/inner", "other"])
        #expect(try names("p|q/s") == ["p", "q/s"])
        // Brackets mean nothing without the leading <.
        #expect(try names("[Y] plain") == ["[Y] plain"])
        #expect(try names("\"file 1.txt\" \"file 2.txt\"", quoted: true) == ["file 1.txt", "file 2.txt"])
        #expect(try names("\"a b.txt\"|\"c.txt\"|d.txt", quoted: true) == ["a b.txt", "c.txt", "d.txt"])
        #expect(try names("").isEmpty)
    }

    /// The date and time placeholders give the parts of the clock, with offsets for what follows them.
    @Test
    internal func dateAndTime() throws {
        #expect(try names("<[Y]-[M]-[D] downloads") == ["2026-10-12 downloads"])
        #expect(try names("<[YMD]_[hms]") == ["20261012_140307"])
        #expect(try names("<[y][M] [Y-M-D] [h.m.s] [v]") == ["2610 2026-10-12 14.03.07 250"])
        #expect(try names("<[H][i] [i1]") == ["02pm p"])
        // Offsets on the time source apply to what follows.
        #expect(try names("<[D] [T2+1D][D] [T2-14h][D] [h]") == ["12 13 12 00"])
        #expect(try names("<[T1+2M][Y]-[M]") == ["2026-12"])
    }

    /// The name, extension, folders and size of the item under the cursor, and ranges of their characters.
    @Test
    internal func partsOfTheNameUnderTheCursor() throws {
        #expect(try names("<Copy of [N]") == ["Copy of Holiday pics"])
        #expect(
            try names("<[A] ([E]) in [P] of [G], [S] bytes") == [
                "Holiday pics.jpeg (jpeg) in Photos of Data, 4096 bytes"
            ]
        )
        #expect(
            try names("<[N1][N-4][N2-5]|[N2,3]|[N9-]|[N-4-]|[N-8-5]|[N2--5]") == [
                "Hpolid", "oli", "pics", "pics", "day", "oliday"
            ]
        )
        #expect(try names("<[E02-9]|[E 1-6]x|[E1-3]") == ["00000peg", "jpegx", "jpe"])
        var folder = context
        folder.cursorName = "My.Folder"
        folder.cursorIsFolder = true
        #expect(try NameTemplate.names(from: "<[N]-[E]-", context: folder) == ["My.Folder--"])
    }

    /// Case switches, environment variables, the clipboard and literal brackets; an empty clipboard is an error.
    @Test
    internal func caseSwitchesEnvironmentClipboardAndBrackets() throws {
        #expect(try names("<[U][N] [L]LOUD [n][E]") == ["HOLIDAY PICS loud jpeg"])
        #expect(try names("<[F]the lord of the rings") == ["The Lord Of The Rings"])
        #expect(try names("<[f]the lord of the rings") == ["The Lord of the Rings"])
        #expect(try names("<[%USER%]_[%LONG%2-4]_[%NONE%]") == ["ada_bcd_"])
        #expect(try names("<[X] [[]x[]]") == ["from_ the _clipboard_ [x]"])
        #expect(try names("<[=tc.size] [Q] [") == ["[=tc.size] [Q] ["])
        var empty = context
        empty.clipboard = nil
        #expect(throws: NameTemplate.Failure.emptyClipboard) { try NameTemplate.names(from: "<[X]", context: empty) }
        #expect(try NameTemplate.names(from: "<a[X+]b", context: empty) == ["ab"])
    }

    /// A counter range at the start makes one name per number, padded as asked; elsewhere it is literal text.
    @Test
    internal func counterRanges() throws {
        // The examples of spec 07 › Counter ranges and optional digit.
        #expect(try names("<1-10>[C]") == ["01", "02", "03", "04", "05", "06", "07", "08", "09", "10"])
        #expect(try names("<1-3>[C]") == ["1", "2", "3"])
        #expect(try names("<1-3>dir[C]") == ["dir1", "dir2", "dir3"])
        #expect(try names("<8-10>Project No [C:3]") == ["Project No 008", "Project No 009", "Project No 010"])
        #expect(try names("<5-6>Example [C] folder") == ["Example 5 folder", "Example 6 folder"])
        #expect(try names("<1-2>[Y]-[M]-[C:2] photos") == ["2026-10-01 photos", "2026-10-02 photos"])
        #expect(try names("<1-3>test[\" (\"C\")\"]") == ["test", "test (2)", "test (3)"])
        #expect(try names("<1-2>[U]part [C] x") == ["PART 1 X", "PART 2 X"])
        // Not at the very start: a literal name.
        #expect(try names("dir<1-3>[C]") == ["dir<1-3>[C]"])
        let preview = NameTemplate.rangePreview("<1-10>[C]", context: context)
        #expect(preview?.first == "01" && preview?.last == "10")
        #expect(NameTemplate.rangePreview("<plain", context: context) == nil)
    }

    /// Without a range the counter takes the first number whose name is free, and fails when none is.
    @Test
    internal func theOptionalDigitFindsTheFirstFreeName() throws {
        var taken = context
        taken.exists = { ["test", "test2", "new", "new (2)", "new (3)"].contains($0) }
        #expect(try NameTemplate.names(from: "<test[C]", context: taken) == ["test3"])
        #expect(try NameTemplate.names(from: "<new[\" (\"C\")\"]", context: taken) == ["new (4)"])
        #expect(try NameTemplate.names(from: "<free[C]|test[C:2]", context: taken) == ["free", "test02"])
        taken.exists = { _ in true }
        #expect(throws: NameTemplate.Failure.noFreeName("full")) {
            try NameTemplate.names(from: "<full[C]", context: taken)
        }
    }
}
