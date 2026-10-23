import Foundation
import Testing

@testable import MultiRenamePlugin

/// The placeholder language, Search & Replace and the planner at their edges: placeholders that
/// are typed wrong, numbers at their limits, expressions that take too long.
@Suite
internal struct CoverageRenameEngine {
    /// 2025-12-01 15:05:09 UTC: an afternoon.
    internal static let afternoon = Date(timeIntervalSince1970: 1_764_601_509)

    /// Three items, in UTC and the POSIX locale, with two environment variables.
    internal var context: RenameContext = {
        var made = RenameContext()
        made.count = 3
        made.timeZone = TimeZone(identifier: "UTC") ?? .current
        made.locale = Locale(identifier: "en_US_POSIX")
        made.environment = ["ROOT": "/", "HOME": "/Users/ada"]
        return made
    }()

    /// A picture in the home folder, changed in the afternoon.
    internal let file = RenameSubject(
        name: "photo.jpg",
        isFolder: false,
        size: 0,
        modified: Self.afternoon,
        directoryPath: "/Users/ada",
        folders: RenameSubject.folders(in: "/Users/ada"),
        url: nil
    )

    /// The name the mask gives `file`, the first of the list, with no extension mask.
    internal func name(_ mask: String) -> String? {
        name(mask, subject: file, index: 0, context: context)
    }

    /// The name the mask gives `subject` at `index` of the list, with no extension mask.
    internal func name(_ mask: String, subject: RenameSubject, index: Int, context: RenameContext) -> String? {
        var settings = RenameSettings()
        settings.nameMask = mask
        settings.extensionMask = ""
        return RenameEngine(settings, context: context).newName(for: subject, index: index)
    }

    /// The name the masks give `subject`, the first of the list, with the settings that `change` makes.
    internal func name(
        _ mask: String,
        ext: String,
        subject: RenameSubject,
        _ change: (inout RenameSettings) -> Void
    ) -> String? {
        var settings = RenameSettings()
        settings.nameMask = mask
        settings.extensionMask = ext
        change(&settings)
        return RenameEngine(settings, context: context).newName(for: subject, index: 0)
    }

    /// What is wrong with the mask, if anything.
    internal func error(_ mask: String) -> RenameMaskError? { RenameMask(mask).error }

    // MARK: Placeholders typed wrong

    /// Placeholders that cannot be read are errors of the mask, which then gives no name.
    @Test
    internal func placeholdersThatCannotBeReadAreErrors() {
        for mask in ["[0]", "[B]", "[B+]", "[B1_x]", "[C+]", "[C/0]", "[C:x]", "[c4]", "[c0]", "[T1+]", "[T1+5x]"] {
            #expect(error(mask) == .invalidPlaceholder(mask), "\(mask)")
            #expect(name(mask) == nil, "\(mask)")
        }
    }

    /// A length left out (`[N2,]`) is no range, and the placeholder is wrong as a whole.
    @Test
    internal func aRangeWithoutItsLengthIsAnError() {
        #expect(error("[N2,]") == .invalidPlaceholder("[N2,]"))
        #expect(name("[N2,3]") == "hot")
    }

    // MARK: Values at their edges

    /// The full path of an item at the top of the disk has one slash.
    @Test
    internal func theFullPathOfAnItemAtTheTop() {
        #expect(
            name(
                "[1-]",
                subject: RenameSubject(
                    name: "a.txt",
                    isFolder: false,
                    size: 0,
                    modified: Date(timeIntervalSince1970: 0),
                    directoryPath: "/",
                    folders: RenameSubject.folders(in: "/"),
                    url: nil
                ),
                index: 0,
                context: context
            ) == "/a.txt"
        )
        #expect(name("[1-]") == "/Users/ada/photo.jpg")
    }

    /// `[I0]` switches the folder dots off again after `[I1]`.
    @Test
    internal func folderDotsCanBeSwitchedOffAgain() {
        let folder = RenameSubject(
            name: "v1.2",
            isFolder: true,
            size: 0,
            modified: Date(timeIntervalSince1970: 0),
            directoryPath: "",
            folders: [],
            url: nil
        )
        #expect(name("[I1][N]", subject: folder, index: 0, context: context) == "v1.2")
        #expect(name("[I1][I0][N]", subject: folder, index: 0, context: context) == "v1")
    }

    /// A counter step can be negative after the plus, and `[c]` is the number of items.
    @Test
    internal func aCounterStepCanBeNegativeAfterThePlus() {
        #expect(name("[C+-5]", subject: file, index: 1, context: context) == "-4")
        #expect(name("[c]") == "3")
    }

    /// The afternoon is written as 15, p and pm; the other fields with their digits.
    @Test
    internal func theAfternoonIsWrittenShort() {
        #expect(name("[h][i1][i]") == "15ppm")
        #expect(name("[Y][y][M][D][m][s][v]") == "20252512010509000")
    }

    /// A time offset moves the date by its unit.
    @Test
    internal func aTimeOffsetMovesTheDate() {
        #expect(name("[T1+2h][h]") == "17")
        #expect(name("[T1-1D][D]") == "30")
    }

    /// A clipboard of empty lines gives nothing for `[X]`.
    @Test
    internal func aClipboardOfEmptyLinesGivesNothing() {
        var withClipboard = context
        withClipboard.clipboard = "\n\n"
        #expect(name("[X]x", subject: file, index: 0, context: withClipboard) == "x")
    }

    /// The path of the top folder has no last part; another path has its last folder.
    @Test
    internal func thePathOfTheTopFolderHasNoLastPart() {
        #expect(name("[%ROOT%\\]x") == "x")
        #expect(name("[%HOME%/]") == "ada")
    }

    /// The smallest number is written whole, and a negative one with its sign before the zeros.
    @Test
    internal func theSmallestNumberIsWrittenWhole() {
        #expect(RenameMask.padded(Int.min, digits: 1) == "-9223372036854775808")
        #expect(RenameMask.padded(-5, digits: 3) == "-005")
    }

    /// Letters count on in base 26, in the case of the start, and too many overflow.
    @Test
    internal func lettersCountOnAndOverflow() throws {
        #expect(try RenameMask.alphabetic("", advancedBy: 3) == "d")
        #expect(try RenameMask.alphabetic("Az", advancedBy: 1) == "BA")
        #expect(throws: RenameMaskError.numberTooLarge) {
            try RenameMask.alphabetic("zzzzzzzzzzzzz", advancedBy: Int.max)
        }
    }

    // MARK: Case and Search & Replace

    /// A title rule without a label is all words; a `!` lets the last word stay small.
    @Test
    internal func aTitleRuleWithoutLabelIsAllWords() {
        let rule = TitleCaseRule(setting: "a, The ,")
        #expect(rule.label == "English in Titles" && rule.words == ["a", "the"] && !rule.allowsLowercaseLastWord)
        let marked = TitleCaseRule(setting: "Mine!:of")
        #expect(marked.label == "Mine" && marked.allowsLowercaseLastWord && marked.words == ["of"])
    }

    /// "First letter uppercase" leaves a name without letters as it is.
    @Test
    internal func firstUpperLeavesANameWithoutLetters() {
        #expect(LetterCase.firstUpper.apply(to: "--_") == "--_")
        #expect(LetterCase.firstUpper.apply(to: "-aB") == "-Ab")
    }

    /// Empty pairs of Search & Replace are skipped.
    @Test
    internal func emptyPairsOfSearchAndReplaceAreSkipped() {
        #expect(
            name("[N]", ext: "[E]", subject: file) { settings in
                settings.search = "o||t"
                settings.replacement = "0||7"
            } == "ph070.jpg"
        )
    }

    /// Groups that took no part, or do not exist, give nothing.
    @Test
    internal func groupsThatTookNoPartGiveNothing() {
        let swapped = name("[N]", ext: "", subject: file) { settings in
            settings.regularExpression = true
            settings.search = "(x)?(photo)"
            settings.replacement = "$1-$2-$9"
        }
        #expect(swapped == "-photo-")
    }

    /// `$10` is a group of two digits only when there are so many groups.
    @Test
    internal func twoDigitGroupsOnlyWhenThereAreSoMany() throws {
        var settings = RenameSettings()
        settings.regularExpression = true
        settings.search = "(p)(h)(o)(t)(o)(\\.)(j)(p)(g)(x)?(y)?"
        settings.replacement = "$11|$10|$1$1"
        #expect(try SearchReplace(settings).apply(to: "photo.jpg") == "||pp")
        settings.search = "(p)"
        settings.replacement = "$10"
        #expect(try SearchReplace(settings).apply(to: "photo.jpg") == "p0hoto.jp0g")
    }

    /// The named groups of the spec's dialect become the system's.
    @Test
    internal func namedGroupsOfTheSpecDialect() {
        #expect(SearchReplace.systemPattern("(?P<a>x)(?P=a)") == "(?<a>x)\\k<a>")
        #expect(SearchReplace.systemPattern("(?'b'y)") == "(?<b>y)")
    }

    /// An expression that takes too long leaves the name as it is through `apply`, and gives no
    /// name (`<Error!>`) where only the name is searched.
    @Test
    internal func anExpressionThatTakesTooLong() throws {
        var settings = RenameSettings()
        settings.regularExpression = true
        settings.search = "(a*)*b"
        settings.replacement = "x"
        let long = String(repeating: "a", count: 40)
        let replace = try SearchReplace(settings)
        #expect(replace.apply(to: long) == long && replace.timedOut)
        let subject = RenameSubject(name: long + ".txt")
        #expect(
            name("[N]", ext: "[E]", subject: subject) { changed in
                changed = settings
                changed.searchesExtension = false
            } == nil
        )
    }
}
