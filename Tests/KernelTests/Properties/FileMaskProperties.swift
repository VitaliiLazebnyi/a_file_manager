import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// `FileMask` against a plain reference implementation of its specification (spec 18 › File
/// masks), written the slow and obvious way: masks separated by spaces or semicolons, `*` for
/// any run of characters, `?` for one character (a Unicode scalar), case and the way accents
/// are written not counting, `*` and `*.*` matching every name, and a mask that ends with a dot
/// matching names without an extension.
@Suite
internal struct FileMaskProperties {
    /// Pieces of masks and names: wildcards, dots, case pairs, accents in one character and in
    /// two, letters whose case forms differ in length, the separators.
    private static let pieces = [
        "*", "?", ".", "a", "A", "b", "\u{E9}", "e\u{301}", "E\u{301}", "\u{DF}", "ss", "\u{212A}", "k", "\u{1F600}",
        "\u{438}", "\u{418}", "[", "\\"
    ]

    /// The form both sides are compared in, as the specification says: without case, accents
    /// composed.
    private static func folded(_ text: String) -> String {
        text.folding(options: .caseInsensitive, locale: nil).precomposedStringWithCanonicalMapping
    }

    /// Whether the scalars of `name` match those of `mask`: a table of which ends of the mask
    /// match which ends of the name, filled from the back.
    private static func wildcard(_ mask: [Unicode.Scalar], _ name: [Unicode.Scalar]) -> Bool {
        // matches[token][index]: the mask from `token` on matches the name from `index` on.
        var matches = [[Bool]](repeating: [Bool](repeating: false, count: name.count + 1), count: mask.count + 1)
        matches[mask.count][name.count] = true
        for token in stride(from: mask.count - 1, through: 0, by: -1) {
            for index in stride(from: name.count, through: 0, by: -1) {
                if mask[token] == "*" {
                    matches[token][index] =
                        matches[token + 1][index] || (index < name.count && matches[token][index + 1])
                } else {
                    matches[token][index] =
                        index < name.count && (mask[token] == "?" || mask[token] == name[index])
                        && matches[token + 1][index + 1]
                }
            }
        }
        return matches[0][0]
    }

    /// The specification, read literally.
    private static func reference(_ text: String, _ name: String) -> Bool {
        let masks = folded(text).split { $0 == " " || $0 == ";" }.map(String.init)
        let scalars = Array(folded(name).unicodeScalars)
        let hasDot = scalars.contains(".")
        return masks.contains { $0 == "*" || $0 == "*.*" }
            || masks.contains { mask in
                let chosen = mask.hasSuffix(".") && !hasDot ? String(mask.dropLast()) : mask
                return wildcard(Array(chosen.unicodeScalars), scalars)
            }
    }

    /// A mask matches a name exactly when the reference says it does.
    @Test
    internal func masksMatchAsTheSpecificationSays() {
        let cases = Generate.text(from: Self.pieces + [" ", ";"], lengths: 0...6)
            .flatMap { mask in Generate.text(from: Self.pieces, lengths: 0...8).map { (mask: mask, name: $0) } }
        expectProperty(cases, count: 5_000) { mask, name in
            FileMask(mask).matches(name) == Self.reference(mask, name)
        }
    }

    /// The same for names of plain ASCII, which take the quick path that compares bytes.
    @Test
    internal func asciiNamesMatchAsTheSpecificationSays() {
        let ascii = ["*", "?", ".", "a", "A", "b", "B", "z", "0"]
        let cases = Generate.text(from: ascii + [" ", ";"], lengths: 0...6)
            .flatMap { mask in Generate.text(from: ascii, lengths: 0...10).map { (mask: mask, name: $0) } }
        expectProperty(cases, count: 5_000) { mask, name in
            FileMask(mask).matches(name) == Self.reference(mask, name)
        }
    }
}
