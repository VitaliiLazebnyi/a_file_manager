import Testing

@testable import AFMKernel

/// File masks and the names they match (review 2, K031, K049).
@Suite
internal struct FileMaskTests {
    /// However an accent is written, in the mask or in the name, the two match.
    @Test
    internal func masksMatchNamesHoweverTheirAccentsAreWritten() {
        let (composed, decomposed) = ("caf\u{E9}.txt", "cafe\u{301}.txt")
        for mask in ["caf\u{E9}*", "cafe\u{301}*", "*\u{E9}.txt", "CAF\u{C9}.TXT", "caf?.txt", "*f?.*"] {
            #expect(FileMask(mask).matches(composed) && FileMask(mask).matches(decomposed), "\(mask.debugDescription)")
        }
        #expect(!FileMask("caf??.txt").matches(composed) && !FileMask("caf??.txt").matches(decomposed))
    }

    /// `?` stands for one character, an emoji or a letter of any script as well as an ASCII one.
    @Test
    internal func aQuestionMarkIsOneCharacterOfAnySize() {
        #expect(FileMask("?.txt").matches("😀.txt") && FileMask("?.txt").matches("写.txt"))
        #expect(FileMask("?.txt").matches("a.txt"))
        #expect(!FileMask("?.txt").matches("ab.txt") && !FileMask("??.txt").matches("😀.txt"))
        #expect(FileMask("写?.jpg").matches("写真.jpg") && FileMask("*?真.JPG").matches("写真.jpg"))
    }

    /// Brackets and backslashes are no pattern syntax: they match themselves.
    @Test
    internal func bracketsAndBackslashesStandForThemselves() {
        #expect(FileMask("report[1].txt").matches("report[1].txt") && !FileMask("report[1].txt").matches("report1.txt"))
        #expect(FileMask("[a-c]*").matches("[a-c] notes.md") && !FileMask("[a-c]*").matches("b.md"))
        #expect(FileMask("a\\b*").matches("a\\b.txt") && FileMask("*[*").matches("x[y"))
        #expect(FileMask("\\*").matches("\\anything"))
    }

    /// Case does not count, in Latin with `ß`, in Cyrillic and with accents; `*.` and `name.`
    /// match names without an extension.
    @Test
    internal func caseDoesNotCountInAnyScript() {
        #expect(FileMask("STRASSE*").matches("straße.txt") && FileMask("straße*").matches("STRASSE.TXT"))
        #expect(FileMask("*ФАЙЛ*").matches("мой файл.txt") && FileMask("*.TXT").matches("отчёт.txt"))
        #expect(FileMask("É*").matches("été"))
        #expect(FileMask("*.").matches("noext") && !FileMask("*.").matches("has.ext"))
        #expect(FileMask("name.").matches("NAME"))
    }

    /// The shapes that make a matcher go back and forth, many `*` against a name that nearly
    /// fits, are answered quickly, bounded by the two lengths multiplied.
    @Test
    internal func noMaskTakesLongOnAnyName() {
        let name = String(repeating: "a", count: 4_000)
        let masks = [
            String(repeating: "*a", count: 60) + "*b", String(repeating: "a*", count: 100) + "?b",
            "*" + String(repeating: "?", count: 300) + "b",
            String(repeating: "*", count: 500) + "b"
        ]
        for mask in masks {
            #expect(!FileMask(mask).matches(name))
            #expect(!FileMask(mask).matches(name + "é"))
            #expect(FileMask(mask).matches(name + "b"))
        }
    }
}
