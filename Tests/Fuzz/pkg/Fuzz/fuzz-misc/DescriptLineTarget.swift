import Foundation
import FuzzCore

@testable import FilePropertiesPlugin

/// The `descript-line` target: one well-formed line, a name without separators, a space, a comment.
@MainActor
internal enum DescriptLineTarget {
    /// The target.
    internal static func make() -> FuzzTarget {
        FuzzTarget(
            "descript-line",
            maxLen: 256,
            dict: ["\u{301}", "\u{600}", "\u{200D}", "\u{FE0F}", "é", ".txt", "\u{20D2}", "\u{1F1E6}"],
            seeds: { seedTexts(["\u{8}file.txt\u{0}a comment", "\u{3}a.b\u{0}x"]) },
            run: run
        )
    }

    /// Reads the line and checks that it names exactly the one entry it was made of.
    private static func run(_ bytes: [UInt8]) {
        var choices = Choices(bytes)
        var name = text(choices.take(Int(choices.byte() % 32)))
        name.unicodeScalars.removeAll { " \"\r\n".unicodeScalars.contains($0) || $0.value == 0xFEFF }
        var comment = text(choices.rest())
        comment.unicodeScalars.removeAll { "\r\n".unicodeScalars.contains($0) }
        comment = DescriptIon.normalized(comment)
        guard !name.isEmpty, !comment.isEmpty, !comment.hasSuffix("\u{04}\u{C2}") else {
            return
        }
        let quoted = choices.bytes.count.isMultiple(of: 2)
        let line = (quoted ? "\"" + name + "\"" : name) + " " + comment + "\r\n"
        let file = DescriptIon(data: Data([0xEF, 0xBB, 0xBF] + Array(line.utf8)))
        let want = DescriptIon.Entry(name: name, comment: comment)
        fzCheck(
            file.entries.count == 1 && Array(file.entries[0].name.utf8) == Array(name.utf8)
                && Array(file.entries[0].comment.utf8) == Array(comment.utf8),
            quoted ? "descript-quoted-line-misread" : "descript-line-misread",
            "line \(line.debugDescription) wanted \(want) got \(file.entries)"
        )
    }
}
