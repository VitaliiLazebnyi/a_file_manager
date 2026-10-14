import Foundation
import FuzzCore

@testable import AFMKernel

/// The `filemask` target: a mask, a newline, a name; the match against the documented rules.
@MainActor
internal enum FileMaskTarget {
    /// The target.
    internal static func make() -> FuzzTarget {
        FuzzTarget(
            "filemask",
            maxLen: 4_096,
            dict: [
                "*", "?", "[", "]", "*.*", "*.", ".", ";", " ", "[!a-z]", "[[:alpha:]]", "\\", "*a*a*a*a*a*a*a*a*b",
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "É", "ß", "İ", "\u{0}"
            ],
            seeds: {
                [
                    "*.txt *.md\nreadme.txt", "report_??.*\nreport_01.pdf", "*a*\nbanana", "*.\nREADME",
                    "[a-c]*;*.JPG\nb.jpg", "*é*\nCAFÉ.TXT", "name.\nname", "*a*a*a*a*a*b\naaaaaaaaaaaaaaaaaaaaaaaa"
                ]
                .map { Array($0.utf8) }
            },
            run: run
        )
    }

    /// Matches once, timing it, and checks the result against the rules.
    private static func run(_ bytes: [UInt8]) {
        var choices = Choices(bytes)
        let pattern = text(choices.until(0x0A))
        let name = text(choices.rest())
        let start = Date()
        let mask = FileMask(pattern)
        let matched = mask.matches(name)
        let elapsed = Date().timeIntervalSince(start)
        if elapsed > FuzzState.slowestMask {
            FuzzState.slowestMask = elapsed
            fzNote(
                "filemask slowest \(Int(elapsed * 1e6)) us pattern=\(pattern.debugDescription.prefix(200))"
                    + " name=\(name.debugDescription.prefix(200))"
            )
        }
        check(mask, pattern: pattern, name: name, matched: matched)
    }

    /// The properties of one match.
    private static func check(_ mask: FileMask, pattern: String, name: String, matched: Bool) {
        // Matching is a function of its arguments, and `*` takes everything.
        fzCheck(
            mask.matches(name) == matched,
            "filemask-unstable",
            "\(pattern.debugDescription) \(name.debugDescription)"
        )
        if !pattern.isEmpty, pattern.allSatisfy({ $0 == "*" }) {
            fzCheck(matched, "filemask-star", name.debugDescription)
        }
        // The rules as `FileMask` states them, worked out the slow way.
        fzCheck(
            matched == MaskReference.matches(pattern, name),
            "filemask-differs-from-rules",
            "mask \(pattern.debugDescription) name \(name.debugDescription): matcher \(matched)"
        )
        // Neither case nor the way an accent is written counts, in the mask or in the name.
        let forms = [
            name.uppercased(), name.lowercased(), name.decomposedStringWithCanonicalMapping,
            name.precomposedStringWithCanonicalMapping
        ]
        for other in forms where MaskReference.folded(other) == MaskReference.folded(name) {
            fzCheck(
                mask.matches(other) == matched,
                "filemask-case-or-accent-form-counts",
                "mask \(pattern.debugDescription) name \(name.debugDescription) other \(other.debugDescription)"
            )
        }
        fzCheck(
            FileMask(pattern.decomposedStringWithCanonicalMapping).matches(name) == matched,
            "filemask-mask-accent-form-counts",
            "mask \(pattern.debugDescription) name \(name.debugDescription)"
        )
    }
}
