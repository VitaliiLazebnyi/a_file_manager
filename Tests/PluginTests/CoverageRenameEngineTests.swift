import AFMKernel
import Foundation
import Testing

@testable import MultiRenamePlugin

/// The placeholder language, Search & Replace and the planner at their edges: placeholders that
/// are typed wrong, numbers at their limits, expressions that take too long.
@Suite
struct CoverageRenameEngine {
    /// 2025-12-01 15:05:09 UTC: an afternoon.
    static let afternoon = Date(timeIntervalSince1970: 1_764_601_509)

    var context: RenameContext = {
        var context = RenameContext()
        context.count = 3
        context.timeZone = TimeZone(identifier: "UTC") ?? .current
        context.locale = Locale(identifier: "en_US_POSIX")
        context.environment = ["ROOT": "/", "HOME": "/Users/ada"]
        return context
    }()

    let file = RenameSubject(name: "photo.jpg", modified: Self.afternoon, directoryPath: "/Users/ada")

    /// The name the masks give, without Search & Replace.
    func name(
        _ mask: String,
        ext: String = "",
        _ subject: RenameSubject? = nil,
        index: Int = 0,
        context: RenameContext? = nil,
        _ change: (inout RenameSettings) -> Void = { _ in }
    ) -> String? {
        var settings = RenameSettings()
        settings.nameMask = mask
        settings.extensionMask = ext
        change(&settings)
        return RenameEngine(settings, context: context ?? self.context).newName(for: subject ?? file, index: index)
    }

    func error(_ mask: String) -> RenameMaskError? { RenameMask(mask).error }

    // MARK: Placeholders typed wrong

    @Test
    func placeholdersThatCannotBeReadAreErrors() {
        for mask in ["[0]", "[B]", "[B+]", "[B1_x]", "[C+]", "[C/0]", "[C:x]", "[c4]", "[c0]", "[T1+]", "[T1+5x]"] {
            #expect(error(mask) == .invalidPlaceholder(mask), "\(mask)")
            #expect(name(mask) == nil, "\(mask)")
        }
    }

    /// A length left out (`[N2,]`) is no range, and the placeholder is wrong as a whole.
    @Test
    func aRangeWithoutItsLengthIsAnError() {
        #expect(error("[N2,]") == .invalidPlaceholder("[N2,]"))
        #expect(name("[N2,3]") == "hot")
    }

    // MARK: Values at their edges

    @Test
    func theFullPathOfAnItemAtTheTop() {
        #expect(name("[1-]", RenameSubject(name: "a.txt", directoryPath: "/")) == "/a.txt")
        #expect(name("[1-]") == "/Users/ada/photo.jpg")
    }

    @Test
    func folderDotsCanBeSwitchedOffAgain() {
        let folder = RenameSubject(name: "v1.2", isFolder: true)
        #expect(name("[I1][N]", folder) == "v1.2")
        #expect(name("[I1][I0][N]", folder) == "v1")
    }

    @Test
    func aCounterStepCanBeNegativeAfterThePlus() {
        #expect(name("[C+-5]", index: 1) == "-4")
        #expect(name("[c]") == "3")
    }

    @Test
    func theAfternoonIsWrittenShort() {
        #expect(name("[h][i1][i]") == "15ppm")
        #expect(name("[Y][y][M][D][m][s][v]") == "20252512010509000")
    }

    @Test
    func aTimeOffsetMovesTheDate() {
        #expect(name("[T1+2h][h]") == "17")
        #expect(name("[T1-1D][D]") == "30")
    }

    @Test
    func aClipboardOfEmptyLinesGivesNothing() {
        var context = context
        context.clipboard = "\n\n"
        #expect(name("[X]x", context: context) == "x")
    }

    @Test
    func thePathOfTheTopFolderHasNoLastPart() {
        #expect(name("[%ROOT%\\]x") == "x")
        #expect(name("[%HOME%/]") == "ada")
    }

    @Test
    func theSmallestNumberIsWrittenWhole() {
        #expect(RenameMask.padded(Int.min, digits: 1) == "-9223372036854775808")
        #expect(RenameMask.padded(-5, digits: 3) == "-005")
    }

    @Test
    func lettersCountOnAndOverflow() throws {
        #expect(try RenameMask.alphabetic("", advancedBy: 3) == "d")
        #expect(try RenameMask.alphabetic("Az", advancedBy: 1) == "BA")
        #expect(throws: RenameMaskError.numberTooLarge) {
            try RenameMask.alphabetic("zzzzzzzzzzzzz", advancedBy: Int.max)
        }
    }

    // MARK: Case and Search & Replace

    @Test
    func aTitleRuleWithoutLabelIsAllWords() {
        let rule = TitleCaseRule(setting: "a, The ,")
        #expect(rule.label == "English in Titles" && rule.words == ["a", "the"] && !rule.allowsLowercaseLastWord)
        let marked = TitleCaseRule(setting: "Mine!:of")
        #expect(marked.label == "Mine" && marked.allowsLowercaseLastWord && marked.words == ["of"])
    }

    @Test
    func firstUpperLeavesANameWithoutLetters() {
        #expect(LetterCase.firstUpper.apply(to: "--_") == "--_")
        #expect(LetterCase.firstUpper.apply(to: "-aB") == "-Ab")
    }

    @Test
    func emptyPairsOfSearchAndReplaceAreSkipped() {
        #expect(
            name("[N]", ext: "[E]") {
                $0.search = "o||t"
                $0.replacement = "0||7"
            } == "ph070.jpg"
        )
    }

    @Test
    func groupsThatTookNoPartGiveNothing() {
        let swapped = name("[N]") {
            $0.regularExpression = true
            $0.search = "(x)?(photo)"
            $0.replacement = "$1-$2-$9"
        }
        #expect(swapped == "-photo-")
    }

    @Test
    func twoDigitGroupsOnlyWhenThereAreSoMany() throws {
        var settings = RenameSettings()
        settings.regularExpression = true
        settings.search = "(p)(h)(o)(t)(o)(\\.)(j)(p)(g)(x)?(y)?"
        settings.replacement = "$11|$10|$1$1"
        #expect(try SearchReplace(settings).apply(to: "photo.jpg") == "||pp")
        settings.search = "(p)"
        settings.replacement = "$10"
        #expect(try SearchReplace(settings).apply(to: "photo.jpg") == "p0hoto.jp0g")
    }

    @Test
    func namedGroupsOfTheSpecDialect() throws {
        #expect(SearchReplace.systemPattern("(?P<a>x)(?P=a)") == "(?<a>x)\\k<a>")
        #expect(SearchReplace.systemPattern("(?'b'y)") == "(?<b>y)")
    }

    /// An expression that takes too long leaves the name as it is through `apply`, and gives no
    /// name (`<Error!>`) where only the name is searched.
    @Test
    func anExpressionThatTakesTooLong() throws {
        var settings = RenameSettings()
        settings.regularExpression = true
        settings.search = "(a*)*b"
        settings.replacement = "x"
        let long = String(repeating: "a", count: 40)
        let replace = try SearchReplace(settings)
        #expect(replace.apply(to: long) == long && replace.timedOut)
        let subject = RenameSubject(name: long + ".txt")
        #expect(
            name("[N]", ext: "[E]", subject) {
                $0 = settings
                $0.searchesExtension = false
            } == nil
        )
    }

    // MARK: The wildcard matcher

    @Test
    func aLetterThatFoldsIntoTwoStaysItself() {
        #expect(WildcardMatcher.folded("\u{130}") == 0x130)
        #expect(WildcardMatcher.folded("Ä") == ("ä" as Unicode.Scalar).value)
    }

    @Test
    func anEmptySearchMatchesNothing() {
        #expect(WildcardMatcher("", caseSensitive: false).matches(in: "abc", firstOnly: false).isEmpty)
    }

    @Test
    func aLongSearchLooksAtTheCancellation() {
        let long = String(repeating: "a", count: 9_000) + "b"
        #expect(WildcardMatcher("*ab", caseSensitive: true).matches(in: long, firstOnly: true).first?.length == 9_001)
        let matcher = WildcardMatcher("a*b", caseSensitive: true)
        #expect(matcher.matches(in: long, firstOnly: true, guardian: RenameRegexGuard(), cancelled: { true }) == nil)
    }

    // MARK: The planner

    func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test
    func aNumberDoesNotFitBesideAVeryLongExtension() {
        let ext = String(repeating: "e", count: 254)
        let numbered = RenamePlanner.numbered(url("/d/a." + ext), 2, isFolder: false)
        #expect(numbered.lastPathComponent == " (2)." + ext)
    }

    @Test
    func anItemWaitingForASkippedOneIsSkippedToo() {
        let planner = RenamePlanner()
        // b and c want x and stay; a wants b's name, which stays taken, and stays too.
        let sources = [url("/d/a"), url("/d/b"), url("/d/c")]
        let targets: [URL?] = [url("/d/b"), url("/d/x"), url("/d/x")]
        let skipped = planner.skippingConflicts(
            sources: sources,
            targets: targets,
            existing: Set(sources.map(planner.key))
        )
        #expect(skipped.allSatisfy { $0 == nil })
    }

    @Test
    func foldersWithNothingOfTheListInsideKeepTheOrder() {
        let planner = RenamePlanner()
        let steps = planner.steps(
            sources: [url("/d/folder"), url("/e/file")],
            targets: [url("/d/folder2"), url("/e/file2")],
            isFolder: [true, false]
        )
        #expect(steps.map(\.item) == [0, 1])
    }

    @Test
    func aPlanCancelledWhileFoldersAreOrderedIsCutShort() {
        let planner = RenamePlanner()
        let asked = CallCounter()
        let steps = planner.steps(
            sources: [url("/d/folder"), url("/d/folder/file")],
            targets: [url("/d/other"), url("/d/folder/file2")],
            isFolder: [true, false],
            cancelled: { asked.next() > 1 }
        )
        #expect(steps.isEmpty && asked.value >= 2)
    }

    /// Counts the calls of a closure.
    ///
    /// Unchecked: the count is guarded by `lock`.
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        /// How often `next` was called.
        var value: Int { lock.withLock { count } }

        /// Counts one more call and returns the count.
        func next() -> Int {
            lock.withLock {
                count += 1
                return count
            }
        }
    }
}
