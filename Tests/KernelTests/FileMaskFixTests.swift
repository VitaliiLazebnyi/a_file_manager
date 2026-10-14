import Foundation
import Testing

@testable import AFMKernel

/// A file mask read once matches every name as the mask spelled out the slow way does.
@Suite
internal struct FileMaskFixTests {
    /// Masks of every shape: case, accents, other scripts, several patterns, brackets, dots.
    private static let masks = [
        "*.txt", "*.TXT", "*", "*.*", "", "*.", "name.", "*report*", "*Re*", "report_??.*", "[a-c]*.md", "*.t?t",
        "a*b*c", "*é*", "*.É",
        "файл*", "*ФАЙЛ*", "*.txt;*.md", "*.txt  *.jpg", "**", "*a.b*", "?", "\\*", "*[*", "x", "*.", "*x.", "*写真*",
        "*.tar.gz", "*ı*", "*k*", "k*", "*σ", "*ς", "*.", "*ss*", "*日本*", "ünï*"
    ]

    /// Names of every shape, to match the masks against.
    private static let names = [
        "report.txt", "REPORT.TXT", "Report_01.Txt", "a.md", "B.MD", "d.md", "name", "NAME", "name.x", "abc",
        "aXbYc", "été.É", "ÉTÉ.é",
        "файл.txt", "ФАЙЛ", "мой файл", "x", "", ".", "a.b", "*", "[", "写真.jpg", "archive.TAR.GZ", "İstanbul",
        "ISTANBUL", "a.b\u{301}", "no ext",
        "\u{212A}elvin.txt", "ΟΔΟΣ.md", "οδος", "straße.TXT", "STRASSE", "ǅ.txt", "名前.", "日本語.TXT", "x.\u{301}",
        "файл", "Ünïcödé.Md"
    ]

    /// The matching spelled out the slow way: both without case and with composed accents,
    /// then character by character (as Unicode numbers them), `*` for any run and `?` for one.
    private static func reference(_ text: String, _ name: String) -> Bool {
        let patterns = fold(text).split { $0 == " " || $0 == ";" }.map(String.init)
        let folded = fold(name)
        return patterns.contains { pattern in
            if pattern == "*.*" || pattern == "*" {
                return true
            }
            let wanted =
                pattern.hasSuffix(".") && !folded.utf8.contains(0x2E) ? String(pattern.dropLast()) : pattern
            return fits(ArraySlice(Array(wanted.unicodeScalars)), ArraySlice(Array(folded.unicodeScalars)))
        }
    }

    /// The text without case and with composed accents.
    private static func fold(_ text: String) -> String {
        text.folding(options: .caseInsensitive, locale: nil).precomposedStringWithCanonicalMapping
    }

    /// Whether `name` fits `pattern`, `*` standing for any run and `?` for one character.
    private static func fits(_ pattern: ArraySlice<Unicode.Scalar>, _ name: ArraySlice<Unicode.Scalar>) -> Bool {
        guard let first = pattern.first else {
            return name.isEmpty
        }
        if first == "*" {
            return (name.startIndex...name.endIndex).contains { fits(pattern.dropFirst(), name[$0...]) }
        }
        guard let character = name.first, first == "?" || first == character else {
            return false
        }
        return fits(pattern.dropFirst(), name.dropFirst())
    }

    /// Checks every mask against every name.
    @Test
    internal func aMaskReadOnceMatchesLikeTheMaskReadEveryTime() {
        for mask in Self.masks {
            let compiled = FileMask(mask)
            for name in Self.names {
                #expect(
                    compiled.matches(name) == Self.reference(mask, name),
                    "\(mask.debugDescription) on \(name.debugDescription)"
                )
            }
        }
    }
}
