import AFMKernel
import Foundation
@testable import MultiRenamePlugin
import Testing

/// The placeholder language, Search & Replace, the case conversions and the planner of the
/// Multi-Rename Tool, without any file system.
@Suite struct MultiRenameEngine {
    /// 2025-12-01 10:05:09.250 UTC.
    static let date = Date(timeIntervalSince1970: 1_764_583_509.25)

    var context: RenameContext = {
        var context = RenameContext()
        context.count = 12
        context.timeZone = TimeZone(identifier: "UTC") ?? .current
        context.locale = Locale(identifier: "en_US_POSIX")
        context.environment = ["USER": "ada", "WORK": "/Users/ada/Work:Files"]
        context.opened = Date(timeIntervalSince1970: 86_400 * 366)
        context.changed = Date(timeIntervalSince1970: 86_400 * 731)
        return context
    }()

    let photo = RenameSubject(name: "IMG_1001.jpg", size: 4711, modified: MultiRenameEngine.date, directoryPath: "/Users/ada/work/photos")

    func name(_ mask: String, ext: String = "[E]", _ subject: RenameSubject? = nil, index: Int = 0,
              _ change: (inout RenameSettings) -> Void = { _ in }, context: RenameContext? = nil) -> String? {
        var settings = RenameSettings()
        settings.nameMask = mask
        settings.extensionMask = ext
        change(&settings)
        return RenameEngine(settings, context: context ?? self.context).newName(for: subject ?? photo, index: index)
    }

    /// The name mask alone, without an extension.
    func part(_ mask: String, _ subject: RenameSubject? = nil, index: Int = 0, context: RenameContext? = nil) -> String? {
        name(mask, ext: "", subject, index: index, context: context)
    }

    // MARK: Masks

    @Test func literalsAndBrackets() {
        #expect(name("[N]") == "IMG_1001.jpg")
        #expect(part("Photo") == "Photo")
        #expect(part("a[[]b[]]c") == "a[b]c")
        #expect(part("[N][E]") == "IMG_1001jpg")
        #expect(name("[N]", ext: "") == "IMG_1001")
        #expect(name("x", ext: "[E]") == "x.jpg")
        #expect(part("[A]") == "IMG_1001.jpg")
        #expect(part("[S]") == "4711")
    }

    @Test func invalidPlaceholdersGiveAnError() {
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

    @Test(arguments: [
        ("[N1]", "a"), ("[N-5]", "e"), ("[N2-5]", "bcde"), ("[N2,5]", "bcdef"), ("[N2-]", "bcdefghi"),
        ("[N-8,5]", "bcdef"), ("[N-8-5]", "bcde"), ("[N2--5]", "bcde"), ("[N-5-]", "efghi"), ("[N20-]", ""),
        ("[N7-20]", "ghi"), ("[N-20-2]", "abcdefgh"),
    ])
    func ranges(mask: String, expected: String) {
        #expect(part(mask, RenameSubject(name: "abcdefghi.txt")) == expected)
    }

    @Test func rangePadding() {
        let short = RenameSubject(name: "abc.txt")
        #expect(part("[N02-9]", short) == "000000bc")
        #expect(part("[N 2-9]", short) == "      bc")
        #expect(part("[N02,4]", short) == "00bc")
        #expect(part("[E1-2]", short) == "tx")
        #expect(part("[A5-]", short) == "txt")
    }

    @Test func rangesCountCharactersNotBytes() {
        #expect(part("[N2-3]", RenameSubject(name: "a😀éz.txt")) == "😀é")
    }

    @Test func pathParts() {
        #expect(part("[P]") == "photos")
        #expect(part("[G]") == "work")
        #expect(part("[P1-3]") == "pho")
        #expect(part("[B0]-[B1]-[B2]-[B9]") == "photos-work-ada-")
        #expect(part("[B+1]-[B+2]-[B+0]") == "Users-ada-")
        #expect(part("[B1_1-2]") == "wo")
        #expect(part("[2-6]") == "Users")
        #expect(part("[-12-]") == "IMG_1001.jpg")
    }

    @Test func foldersAndTheFolderDotSwitch() {
        let folder = RenameSubject(name: "release.v2", isFolder: true)
        #expect(name("[N]", ext: "[E]", folder) == "release.v2")
        #expect(name("[N]_x", ext: "[E]", folder) == "release_x.v2")
        #expect(name("[I][N]_x", ext: "[E]", folder) == "release.v2_x")
        #expect(name("[I][N]_x", ext: "[E]") == "IMG_1001_x.jpg")
        #expect(name("[I][I0][N]_x", ext: "[E]", folder) == "release_x.v2")
        #expect(name("[I][I][N]_x", ext: "[E]", folder) == "release_x.v2")
        #expect(part("[N]", RenameSubject(name: ".zshrc")) == ".zshrc")
    }

    @Test func counters() {
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

    @Test func definedCounter() {
        func counted(_ mask: String, _ counter: CounterDefinition, index: Int) -> String? {
            name(mask, ext: "", index: index) { $0.counter = counter }
        }
        let definition = CounterDefinition(start: 110, step: 15, digits: 1)
        #expect((0..<2).map { counted("Photo_[C]_[Y]-[M]-[D]", definition, index: $0) } == ["Photo_110_2025-12-01", "Photo_125_2025-12-01"])
        #expect(counted("[C]", CounterDefinition(start: 1, step: 1, digits: 4), index: 6) == "0007")
        #expect(counted("[C]", CounterDefinition(start: 5, step: -2, digits: 2), index: 4) == "-03")
        #expect(counted("[C]", CounterDefinition(start: 1, step: 1, digits: 0), index: 0) == "01")
        #expect(counted("[c2]", CounterDefinition(start: 1, step: 1, digits: 4), index: 0) == "0012")
        #expect(counted("[c3]", definition, index: 0) == "275")
        // An inline definition ignores the fields.
        #expect(counted("[C3]", definition, index: 1) == "4")
    }

    @Test func dateAndTime() {
        #expect(part("[YMD]_[hms]") == "20251201_100509")
        #expect(part("[Y]-[M]-[D] [h].[m].[s].[v]") == "2025-12-01 10.05.09.250")
        #expect(part("[y][H][i][i1]") == "2510ama")
        #expect(part("[d]") == "12-1-25")
        #expect(part("[t]") == "10.05.09 AM")
        let evening = RenameSubject(name: "a", modified: MultiRenameEngine.date.addingTimeInterval(3 * 3600))
        #expect(part("[h]-[H]-[i]", evening) == "13-01-pm")
        #expect(part("[H]", RenameSubject(name: "a", modified: Date(timeIntervalSince1970: 0))) == "12")
    }

    @Test func timeSourcesAndOffsets() {
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

    @Test func caseSwitches() {
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

    @Test func environmentAndClipboard() {
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

    // MARK: Search & Replace

    func replaced(_ name: String, _ search: String, _ replacement: String, _ change: (inout RenameSettings) -> Void = { _ in }) -> String? {
        var settings = RenameSettings()
        settings.search = search
        settings.replacement = replacement
        change(&settings)
        return RenameEngine(settings, context: context).newName(for: RenameSubject(name: name), index: 0)
    }

    @Test func plainSearchAndReplace() {
        #expect(replaced("Holiday holiday.txt", "HOLIDAY", "trip") == "trip trip.txt")
        #expect(replaced("Holiday holiday.txt", "holiday", "trip") { $0.caseSensitive = true } == "Holiday trip.txt")
        #expect(replaced("Holiday holiday.txt", "holiday", "trip") { $0.firstOnly = true } == "trip holiday.txt")
        #expect(replaced("a.b.c.txt", ".", "_") == "a_b_c_txt")
        #expect(replaced("a.b.c.txt", ".", "_") { $0.searchesExtension = false } == "a_b_c.txt")
        #expect(replaced("price $1 (x).txt", "$1 (x)", "[$2]") == "price [$2].txt")
        #expect(replaced("abc.txt", "", "x") == "abc.txt")
        #expect(replaced("abc.txt", "b", "") == "ac.txt")
    }

    @Test func severalPairsAndWildcards() {
        #expect(replaced("Bär Öl über.txt", "ä|ö|ü", "ae|oe|ue") == "Baer oel ueber.txt")
        #expect(replaced("Bär Öl.txt", "ä|Ö", "ae|OE") { $0.caseSensitive = true } == "Baer OEl.txt")
        #expect(replaced("a-b_c.txt", "-|_", " ") == "a bc.txt")
        #expect(replaced("abxcdx.txt", "*x", "") == "cdx.txt")
        #expect(replaced("abxcdx.txt", "*x", "") { $0.firstOnly = true } == "cdx.txt")
        #expect(replaced("photo (copy 12).jpg", " (copy ??)", "") == "photo.jpg")
        #expect(replaced("name - draft.txt", " - *", "") { $0.searchesExtension = false } == "name.txt")
    }

    @Test func regularExpressions() {
        func regex(_ name: String, _ search: String, _ replacement: String, _ change: (inout RenameSettings) -> Void = { _ in }) -> String? {
            replaced(name, search, replacement) { settings in
                settings.regularExpression = true
                change(&settings)
            }
        }
        #expect(regex("IMG_1001.jpg", #"IMG_(\d)(\d+)"#, "pic-$2-$1") == "pic-001-1.jpg")
        #expect(regex("IMG_1001.jpg", #"IMG_(\d)(\d+)"#, "pic-$2-$1") { $0.letterCase = .upper } == "PIC-001-1.JPG")
        #expect(regex("img_1.JPG", "IMG", "x") == "x_1.JPG")
        #expect(regex("img_1.JPG", "IMG", "x") { $0.caseSensitive = true } == "img_1.JPG")
        #expect(regex("aXbXc.txt", "x", "-") { $0.firstOnly = true } == "a-bXc.txt")
        #expect(regex("queen - bohemian.mp3", #"(.*) - (.*)\.mp3"#, #"\U$2 - \F$1.mp3"#) == "BOHEMIAN - Queen.mp3")
        #expect(regex("Queen - Song.mp3", #"(.*) - (.*)"#, #"\L$1 $2"#) == "queen Song.mp3")
        #expect(regex("a.txt", "a", #"\\$0\$1"#) == #"\a$1.txt"#)
        #expect(regex("abcdefghijkl.txt", "(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)(k)(l)", "$12$11$10$1") == "lkja.txt")
        #expect(regex("ab.txt", "(a)(b)", "$10$2") == "a0b.txt")
        #expect(regex("part1_part2.txt", "(?:.*)_(.*)", "$1") == "part2.txt")
        #expect(regex("x.txt", "(", "y") == nil)
    }

    @Test func regularExpressionSubstitutionAndDialect() {
        func subst(_ name: String, _ search: String, _ replacement: String, ext: Bool = true) -> String? {
            replaced(name, search, replacement) { settings in
                settings.regularExpression = true
                settings.substitute = true
                settings.searchesExtension = ext
            }
        }
        #expect(subst("Track 07 of album.mp3", #"(\d+)"#, "No$1") == "No07")
        #expect(subst("Track 07 of album.mp3", #"(\d+)"#, "No$1", ext: false) == "No07.mp3")
        #expect(subst("no digits.txt", #"(\d+)"#, "No$1") == "no digits.txt")
        // Without RegEx, Subst. has no effect.
        #expect(replaced("abc.txt", "b", "x") { $0.substitute = true } == "axc.txt")
        #expect(SearchReplace.systemPattern("(?P<n>a)(?P=n)") == #"(?<n>a)\k<n>"#)
        #expect(SearchReplace.systemPattern("(?'n'a)(?g)b") == "(?<n>a)b")
        #expect(SearchReplace.systemPattern("^??a") == "^?a")
        #expect(SearchReplace.wildcardPattern("a*b?.*") == #"a.*?b.\..*"# && SearchReplace.wildcardPattern("*x") == "^.*?x")
        #expect(replaced("aa-b.txt", "(?P<x>a)(?P=x)", "$1") { $0.regularExpression = true } == "a-b.txt")
        #expect(replaced("q.txt", "q(?!u)", "k") { $0.regularExpression = true } == "k.txt")
    }

    // MARK: Case conversion and the pipeline

    @Test func letterCases() {
        let rule = TitleCaseRule.standard
        #expect(LetterCase.unchanged.apply(to: "aB c.TXT") == "aB c.TXT")
        #expect(LetterCase.lower.apply(to: "aB c.TXT") == "ab c.txt")
        #expect(LetterCase.upper.apply(to: "aB c.txt") == "AB C.TXT")
        #expect(LetterCase.firstUpper.apply(to: "hELLO wORLD.TXT") == "Hello world.txt")
        #expect(LetterCase.firstUpper.apply(to: "(draft) NOTE") == "(Draft) note")
        #expect(LetterCase.words.apply(to: "hELLO big-wORLD_x/y.TXT") == "Hello Big-World_X/Y.txt")
        #expect(LetterCase.titleWords.apply(to: "the war OF the worlds.txt", rule: rule) == "The War of the Worlds.txt")
        #expect(LetterCase.titleWords.apply(to: "what is it for.txt", rule: rule) == "What Is It For.txt")
        let loose = TitleCaseRule(setting: "My words!:is,for")
        #expect(loose.allowsLowercaseLastWord && loose.label == "My words" && loose.words == ["is", "for"])
        #expect(LetterCase.titleWords.apply(to: "what is it for", rule: loose) == "What is It for")
        #expect(TitleCaseRule.standard.words.contains("vs") && !TitleCaseRule.standard.allowsLowercaseLastWord)
    }

    @Test func pipelineOrderAndGivenNames() {
        // Masks, then Search & Replace, then the case conversion over the whole name.
        #expect(name("[N]_new", ext: "[E]") { $0.search = "IMG_"; $0.replacement = "pic"; $0.letterCase = .upper } == "PIC1001_NEW.JPG")
        var settings = RenameSettings()
        settings.search = "."
        settings.replacement = " "
        settings.searchesExtension = false
        let engine = RenameEngine(settings, context: context)
        // With given names everything from the last dot on is protected.
        #expect(engine.newName(for: photo, index: 0, given: "a.b.c.txt") == "a b c.txt")
        #expect(engine.newName(for: photo, index: 0, given: "plain") == "plain")
        #expect(RenameEngine(RenameSettings(), context: context).newName(for: photo, index: 0, given: "x.") == "x.")
        #expect(RenameEngine.tidied("a\tb\u{1}c//") == "a b c")
    }

    @Test func invalidNames() {
        #expect(RenameEngine.invalidity(of: "") != nil)
        #expect(RenameEngine.invalidity(of: "a//b") != nil)
        #expect(RenameEngine.invalidity(of: "sub/../x") != nil)
        #expect(RenameEngine.invalidity(of: ".") != nil)
        #expect(RenameEngine.invalidity(of: String(repeating: "ä", count: 128)) != nil)
        #expect(RenameEngine.invalidity(of: "sub/dir/x.txt") == nil)
        #expect(RenameEngine.invalidity(of: "/abs/x.txt") == nil)
        #expect(RenameEngine.invalidity(of: ".hidden") == nil)
    }

    @Test func nameLists() {
        #expect(RenameNameList.names(in: "a.txt\r\nb.txt\n\nc.txt\n\n") == ["a.txt", "b.txt", "", "c.txt"])
        #expect(RenameNameList.text(from: Data([0xEF, 0xBB, 0xBF] + Array("ä\n".utf8))) == "ä\n")
        #expect(RenameNameList.text(from: "ä b".data(using: .utf16) ?? Data()) == "ä b")
        #expect(RenameNameList.text(from: "ab".data(using: .utf16LittleEndian) ?? Data()) == "ab")
        #expect(RenameNameList.text(from: Data([0x61, 0xE4])) == "aä")
    }

    @Test func manyNamesOnAllCoresKeepTheirOrder() {
        let registry = FileSystemRegistry()
        let entries = (0..<5000).map { RenameEntry(FileItem(url: URL(fileURLWithPath: "/nowhere/f\($0).txt"), name: "f\($0).txt", isDirectory: false)) }
        var settings = RenameSettings()
        settings.nameMask = "[N]-[C:5]"
        let names = RenameComputation.names(entries, settings: settings, context: context, given: nil, fileSystems: registry).names
        #expect(names.count == 5000 && names[0] == "f0-00001.txt" && names[4999] == "f4999-05000.txt")
        #expect(names.enumerated().allSatisfy { $0.element == String(format: "f%d-%05d.txt", $0.offset, $0.offset + 1) })
    }
}

/// Collisions and the order of a set of renames.
@Suite struct MultiRenamePlanning {
    func url(_ name: String) -> URL { URL(fileURLWithPath: "/d/" + name) }
    func urls(_ names: [String?]) -> [URL?] { names.map { $0.map(url) } }

    /// Carries the steps out on a set of names and returns what is there afterwards; a step
    /// onto a taken name or from a missing one fails the test.
    func simulate(_ names: [String], _ steps: [RenameStep], foldsCase: Bool = false) -> [String] {
        func fold(_ name: String) -> String { foldsCase ? name.lowercased() : name }
        var present = names
        for step in steps {
            let (from, to) = (step.from.lastPathComponent, step.to.lastPathComponent)
            guard let index = present.firstIndex(of: from) else {
                Issue.record("\(from) is not there")
                continue
            }
            let taken = present.enumerated().contains { $0.offset != index && fold($0.element) == fold(to) }
            #expect(!taken, "\(to) is taken")
            #expect(step.ontoItself == (fold(from) == fold(to) && step.kind == .direct))
            present[index] = to
        }
        return present
    }

    func plan(_ renames: [(String, String?)], foldsCase: Bool = false) -> [RenameStep] {
        RenamePlanner(foldsCase: foldsCase).steps(sources: renames.map { url($0.0) }, targets: urls(renames.map(\.1)), temporaryName: { "tmp\($0)" })
    }

    @Test func plainRenamesKeepListOrder() {
        let steps = plan([("a", "x"), ("b", "b"), ("c", nil), ("d", "y")])
        #expect(steps.map(\.item) == [0, 3] && steps.allSatisfy { $0.kind == .direct && !$0.ontoItself })
        #expect(simulate(["a", "b", "c", "d"], steps) == ["x", "b", "c", "y"])
    }

    @Test func chainsWaitForTheirPlace() {
        // 1 → 2 → 3 → 4: the last has to move first.
        let steps = plan([("1", "2"), ("2", "3"), ("3", "4")])
        #expect(steps.map(\.item) == [2, 1, 0] && steps.allSatisfy { $0.kind == .direct })
        #expect(simulate(["1", "2", "3"], steps) == ["2", "3", "4"])
        let reversed = plan([("3", "4"), ("2", "3"), ("1", "2")])
        #expect(reversed.map(\.item) == [0, 1, 2])
    }

    @Test func swapsAndRingsGoThroughATemporaryName() {
        let swap = plan([("1.txt", "2.txt"), ("2.txt", "1.txt")])
        #expect(swap.map(\.kind) == [.park, .direct, .unpark])
        #expect(swap.map(\.item) == [0, 1, 0] && swap[0].to.lastPathComponent == "tmp0")
        #expect(simulate(["1.txt", "2.txt"], swap) == ["2.txt", "1.txt"])

        let ring = plan([("a", "b"), ("b", "c"), ("c", "a"), ("x", "y")])
        #expect(ring.filter { $0.kind == .park }.count == 1 && ring.count == 5)
        #expect(simulate(["a", "b", "c", "x"], ring) == ["b", "c", "a", "y"])

        // Two rings and a chain that leads into one of them.
        let mixed = plan([("p", "a"), ("a", "b"), ("b", "a"), ("m", "n"), ("n", "m")])
        #expect(mixed.filter { $0.kind == .park }.count == 2)
        #expect(simulate(["p", "a", "b", "m", "n"], Array(mixed.dropLast(0)).filter { $0.item != 0 }) == ["p", "b", "a", "n", "m"])
    }

    @Test func aLongChainNeedsNoRecursion() {
        let count = 20_000
        let renames = (0..<count).map { (String($0), Optional(String($0 + 1))) }
        let steps = plan(renames)
        #expect(steps.count == count && steps.first?.item == count - 1 && steps.last?.item == 0)
    }

    @Test func caseOnlyRenames() {
        // Where case is not told apart the rename lands on the file itself…
        let folded = plan([("readme.TXT", "README.txt")], foldsCase: true)
        #expect(folded.count == 1 && folded[0].ontoItself)
        #expect(simulate(["readme.TXT"], folded, foldsCase: true) == ["README.txt"])
        // …elsewhere it is a rename like any other.
        let exact = plan([("readme.TXT", "README.txt")])
        #expect(exact.count == 1 && !exact[0].ontoItself)
        // A swap of two names that differ in case only from each other's.
        let swap = plan([("A", "b"), ("B", "a")], foldsCase: true)
        #expect(swap.map(\.kind) == [.park, .direct, .unpark])
        #expect(simulate(["A", "B"], swap, foldsCase: true) == ["b", "a"])
    }

    func conflicts(_ renames: [(String, String?)], existing: [String], foldsCase: Bool = false) -> [Int: RenameStatus] {
        let planner = RenamePlanner(foldsCase: foldsCase)
        return planner.conflicts(sources: renames.map { url($0.0) }, targets: urls(renames.map(\.1)),
                                 existing: Set(existing.map { planner.key(url($0)) }))
    }

    @Test func conflictDetection() {
        #expect(conflicts([("a", "x"), ("b", "x"), ("c", "y")], existing: ["a", "b", "c"]) == [0: .duplicate, 1: .duplicate])
        #expect(conflicts([("a", "z"), ("b", "y")], existing: ["a", "b", "z"]) == [0: .exists])
        // A name that an item of the list gives up is free; one it keeps is not.
        #expect(conflicts([("a", "b"), ("b", "c")], existing: ["a", "b"]).isEmpty)
        #expect(conflicts([("a", "b"), ("b", "b")], existing: ["a", "b"]) == [0: .duplicate])
        #expect(conflicts([("a", "b"), ("b", nil)], existing: ["a", "b"]) == [0: .duplicate])
        #expect(conflicts([("a", "b"), ("b", "a")], existing: ["a", "b"]).isEmpty)
        #expect(conflicts([("a", "sub/x")], existing: ["a", "sub/x"]) == [0: .exists])
    }

    @Test func conflictsAndLetterCase() {
        #expect(conflicts([("a", "A")], existing: ["a"], foldsCase: true).isEmpty)
        #expect(conflicts([("a", "X"), ("b", "x")], existing: ["a", "b"], foldsCase: true) == [0: .duplicate, 1: .duplicate])
        #expect(conflicts([("a", "X"), ("b", "x")], existing: ["a", "b"]).isEmpty)
        #expect(conflicts([("a", "Z")], existing: ["a", "z"], foldsCase: true) == [0: .exists])
        #expect(conflicts([("a", "Z")], existing: ["a", "z"]).isEmpty)
    }

    @Test func autoRename() {
        let planner = RenamePlanner()
        func resolved(_ renames: [(String, String?)], existing: [String], folders: Set<Int> = []) -> [String?] {
            planner.autoRenamed(sources: renames.map { url($0.0) }, targets: urls(renames.map(\.1)),
                                isFolder: renames.indices.map(folders.contains), existing: Set(existing.map { planner.key(url($0)) }))
                .map { $0?.lastPathComponent }
        }
        #expect(resolved([("a.txt", "x.txt"), ("b.txt", "x.txt"), ("c.txt", "x.txt")], existing: ["a.txt", "b.txt", "c.txt"])
                == ["x.txt", "x (2).txt", "x (3).txt"])
        #expect(resolved([("a.txt", "z.txt")], existing: ["a.txt", "z.txt", "z (2).txt"]) == ["z (3).txt"])
        // A number that another item of the list is about to take is passed over.
        #expect(resolved([("a", "x"), ("b", "x"), ("c", "x (2)")], existing: ["a", "b", "c"]) == ["x", "x (3)", "x (2)"])
        #expect(resolved([("a", "v1.2"), ("b", "v1.2")], existing: ["a", "b"], folders: [0, 1]) == ["v1.2", "v1.2 (2)"])
        // Unchanged and case-only renames are left alone.
        #expect(resolved([("a", "a"), ("b", "a"), ("c", nil)], existing: ["a", "b", "c"]) == ["a", "a (2)", nil])
        let after = resolved([("a.txt", "x.txt"), ("b.txt", "x.txt")], existing: ["a.txt", "b.txt"])
        #expect(planner.conflicts(sources: [url("a.txt"), url("b.txt")], targets: urls(after), existing: []).isEmpty)
    }
}
