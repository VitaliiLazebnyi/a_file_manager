import AFMKernel
import Foundation
import Testing

@testable import MultiRenamePlugin

/// Search & Replace, the case conversions and the whole pipeline.
extension MultiRenameEngine {
    /// The new name of a file named `name` when `search` is replaced by `replacement`.
    internal func replaced(_ name: String, _ search: String, _ replacement: String) -> String? {
        replaced(name, search, replacement, Self.asTheyAre)
    }

    /// The new name of a file named `name` when `search` is replaced by `replacement`, the settings changed
    /// by `change` first.
    internal func replaced(
        _ name: String,
        _ search: String,
        _ replacement: String,
        _ change: (inout RenameSettings) -> Void
    ) -> String? {
        var settings = RenameSettings()
        settings.search = search
        settings.replacement = replacement
        change(&settings)
        return RenameEngine(settings, context: context).newName(for: RenameSubject(name: name), index: 0)
    }

    /// The plain search replaces every occurrence, without regard to case unless asked, and in the
    /// extension unless told not to.
    @Test
    internal func plainSearchAndReplace() {
        #expect(replaced("Holiday holiday.txt", "HOLIDAY", "trip") == "trip trip.txt")
        #expect(replaced("Holiday holiday.txt", "holiday", "trip") { $0.caseSensitive = true } == "Holiday trip.txt")
        #expect(replaced("Holiday holiday.txt", "holiday", "trip") { $0.firstOnly = true } == "trip holiday.txt")
        #expect(replaced("a.b.c.txt", ".", "_") == "a_b_c_txt")
        #expect(replaced("a.b.c.txt", ".", "_") { $0.searchesExtension = false } == "a_b_c.txt")
        #expect(replaced("price $1 (x).txt", "$1 (x)", "[$2]") == "price [$2].txt")
        #expect(replaced("abc.txt", "", "x") == "abc.txt")
        #expect(replaced("abc.txt", "b", "") == "ac.txt")
    }

    /// Several pairs separated by `|`, and the wildcards `*` and `?`.
    @Test
    internal func severalPairsAndWildcards() {
        #expect(replaced("Bär Öl über.txt", "ä|ö|ü", "ae|oe|ue") == "Baer oel ueber.txt")
        #expect(replaced("Bär Öl.txt", "ä|Ö", "ae|OE") { $0.caseSensitive = true } == "Baer OEl.txt")
        #expect(replaced("a-b_c.txt", "-|_", " ") == "a bc.txt")
        #expect(replaced("abxcdx.txt", "*x", "") == "cdx.txt")
        #expect(replaced("abxcdx.txt", "*x", "") { $0.firstOnly = true } == "cdx.txt")
        #expect(replaced("photo (copy 12).jpg", " (copy ??)", "") == "photo.jpg")
        #expect(replaced("name - draft.txt", " - *", "") { $0.searchesExtension = false } == "name.txt")
    }

    /// Regular expressions with groups, case switches in the replacement and two-digit groups; a broken one
    /// gives no name.
    @Test
    internal func regularExpressions() {
        func regex(
            _ name: String,
            _ search: String,
            _ replacement: String,
            _ change: (inout RenameSettings) -> Void
        ) -> String? {
            replaced(name, search, replacement) { settings in
                settings.regularExpression = true
                change(&settings)
            }
        }
        #expect(regex("IMG_1001.jpg", #"IMG_(\d)(\d+)"#, "pic-$2-$1", Self.asTheyAre) == "pic-001-1.jpg")
        #expect(regex("IMG_1001.jpg", #"IMG_(\d)(\d+)"#, "pic-$2-$1") { $0.letterCase = .upper } == "PIC-001-1.JPG")
        #expect(regex("img_1.JPG", "IMG", "x", Self.asTheyAre) == "x_1.JPG")
        #expect(regex("img_1.JPG", "IMG", "x") { $0.caseSensitive = true } == "img_1.JPG")
        #expect(regex("aXbXc.txt", "x", "-") { $0.firstOnly = true } == "a-bXc.txt")
        #expect(
            regex("queen - bohemian.mp3", #"(.*) - (.*)\.mp3"#, #"\U$2 - \F$1.mp3"#, Self.asTheyAre)
                == "BOHEMIAN - Queen.mp3"
        )
        #expect(regex("Queen - Song.mp3", #"(.*) - (.*)"#, #"\L$1 $2"#, Self.asTheyAre) == "queen Song.mp3")
        #expect(regex("a.txt", "a", #"\\$0\$1"#, Self.asTheyAre) == #"\a$1.txt"#)
        #expect(
            regex("abcdefghijkl.txt", "(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)(k)(l)", "$12$11$10$1", Self.asTheyAre)
                == "lkja.txt"
        )
        #expect(regex("ab.txt", "(a)(b)", "$10$2", Self.asTheyAre) == "a0b.txt")
        #expect(regex("part1_part2.txt", "(?:.*)_(.*)", "$1", Self.asTheyAre) == "part2.txt")
        #expect(regex("x.txt", "(", "y", Self.asTheyAre) == nil)
    }

    /// Subst. replaces the whole name by the replacement, and the spec's dialect is turned into the system's.
    @Test
    internal func regularExpressionSubstitutionAndDialect() {
        func subst(_ name: String, _ search: String, _ replacement: String, ext: Bool) -> String? {
            replaced(name, search, replacement) { settings in
                settings.regularExpression = true
                settings.substitute = true
                settings.searchesExtension = ext
            }
        }
        #expect(subst("Track 07 of album.mp3", #"(\d+)"#, "No$1", ext: true) == "No07")
        #expect(subst("Track 07 of album.mp3", #"(\d+)"#, "No$1", ext: false) == "No07.mp3")
        #expect(subst("no digits.txt", #"(\d+)"#, "No$1", ext: true) == "no digits.txt")
        // Without RegEx, Subst. has no effect.
        #expect(replaced("abc.txt", "b", "x") { $0.substitute = true } == "axc.txt")
        #expect(SearchReplace.systemPattern("(?P<n>a)(?P=n)") == #"(?<n>a)\k<n>"#)
        #expect(SearchReplace.systemPattern("(?'n'a)(?g)b") == "(?<n>a)b")
        #expect(SearchReplace.systemPattern("^??a") == "^?a")
        #expect(
            SearchReplace.wildcardPattern("a*b?.*") == #"a.*?b.\..*"# && SearchReplace.wildcardPattern("*x") == "^.*?x"
        )
        #expect(replaced("aa-b.txt", "(?P<x>a)(?P=x)", "$1") { $0.regularExpression = true } == "a-b.txt")
        #expect(replaced("q.txt", "q(?!u)", "k") { $0.regularExpression = true } == "k.txt")
    }

    // MARK: Case conversion and the pipeline

    /// The case conversions, and the words title case keeps in lower case.
    @Test
    internal func letterCases() {
        let rule = TitleCaseRule.standard
        #expect(LetterCase.unchanged.apply(to: "aB c.TXT") == "aB c.TXT")
        #expect(LetterCase.lower.apply(to: "aB c.TXT") == "ab c.txt")
        #expect(LetterCase.upper.apply(to: "aB c.txt") == "AB C.TXT")
        #expect(LetterCase.firstUpper.apply(to: "hELLO wORLD.TXT") == "Hello world.txt")
        #expect(LetterCase.firstUpper.apply(to: "(draft) NOTE") == "(Draft) note")
        #expect(LetterCase.words.apply(to: "hELLO big-wORLD_x/y.TXT") == "Hello Big-World_X/Y.txt")
        #expect(
            LetterCase.titleWords.apply(to: "the war OF the worlds.txt", rule: rule) == "The War of the Worlds.txt"
        )
        #expect(LetterCase.titleWords.apply(to: "what is it for.txt", rule: rule) == "What Is It For.txt")
        let loose = TitleCaseRule(setting: "My words!:is,for")
        #expect(loose.allowsLowercaseLastWord && loose.label == "My words" && loose.words == ["is", "for"])
        #expect(LetterCase.titleWords.apply(to: "what is it for", rule: loose) == "What is It for")
        #expect(TitleCaseRule.standard.words.contains("vs") && !TitleCaseRule.standard.allowsLowercaseLastWord)
    }

    /// Masks, then Search & Replace, then the case conversion; a given name keeps what follows its last dot.
    @Test
    internal func pipelineOrderAndGivenNames() {
        // Masks, then Search & Replace, then the case conversion over the whole name.
        #expect(
            name("[N]_new", ext: "[E]") { settings in
                settings.search = "IMG_"
                settings.replacement = "pic"
                settings.letterCase = .upper
            } == "PIC1001_NEW.JPG"
        )
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

    /// The names that cannot be given to a file, and those that can.
    @Test
    internal func invalidNames() {
        #expect(RenameEngine.invalidity(of: "") != nil)
        #expect(RenameEngine.invalidity(of: "a//b") != nil)
        #expect(RenameEngine.invalidity(of: "sub/../x") != nil)
        #expect(RenameEngine.invalidity(of: ".") != nil)
        #expect(RenameEngine.invalidity(of: String(repeating: "ä", count: 128)) != nil)
        #expect(RenameEngine.invalidity(of: "sub/dir/x.txt") == nil)
        #expect(RenameEngine.invalidity(of: "/abs/x.txt") == nil)
        #expect(RenameEngine.invalidity(of: ".hidden") == nil)
    }

    /// A name list is read in each of its encodings and split into lines.
    @Test
    internal func nameLists() {
        #expect(RenameNameList.names(in: "a.txt\r\nb.txt\n\nc.txt\n\n") == ["a.txt", "b.txt", "", "c.txt"])
        #expect(RenameNameList.text(from: Data([0xEF, 0xBB, 0xBF] + Array("ä\n".utf8))) == "ä\n")
        #expect(RenameNameList.text(from: "ä b".data(using: .utf16) ?? Data()) == "ä b")
        #expect(RenameNameList.text(from: "ab".data(using: .utf16LittleEndian) ?? Data()) == "ab")
        #expect(RenameNameList.text(from: Data([0x61, 0xE4])) == "aä")
    }

    /// Names computed on all cores keep the order of the list.
    @Test
    internal func manyNamesOnAllCoresKeepTheirOrder() {
        let registry = FileSystemRegistry()
        let entries = (0..<5_000)
            .map { index in
                RenameEntry(FileItem(url: URL(fileURLWithPath: "/nowhere/f\(index).txt"), name: "f\(index).txt"))
            }
        var settings = RenameSettings()
        settings.nameMask = "[N]-[C:5]"
        let names =
            RenameComputation.names(
                RenameRequest(entries: entries, settings: settings, context: context),
                fileSystems: registry,
                subjects: []
            ) { false }
            .names
        #expect(names.count == 5_000 && names[0] == "f0-00001.txt" && names[4_999] == "f4999-05000.txt")
        #expect(
            names.enumerated().allSatisfy { $0.element == String(format: "f%d-%05d.txt", $0.offset, $0.offset + 1) }
        )
    }
}
