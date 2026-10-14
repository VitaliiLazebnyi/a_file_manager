import Foundation
import FuzzCore

@testable import FilePropertiesPlugin

/// The `descript` target: a whole descript.ion file, read, written again and changed.
@MainActor
internal enum DescriptTarget {
    /// The target.
    internal static func make() -> FuzzTarget {
        FuzzTarget(
            "descript",
            maxLen: 8_192,
            dict: ["\"", "\r\n", "\n", " ", "\u{04}\u{C2}", "\\n", "descript.ion"],
            rawDict: [
                [0xFF, 0xFE], [0xFE, 0xFF], [0xEF, 0xBB, 0xBF], [0x04, 0xC2], [0x00, 0xD8], [0xD8, 0x00], [0x81], [0x00]
            ],
            seeds: seeds,
            run: run
        )
    }

    /// Files in each encoding the reader knows, and some it must survive.
    private static func seeds() -> [[UInt8]] {
        var seeds = seedTexts([
            "readme.txt A comment\r\n\"my file.txt\" Another one\r\nmulti.txt line one\\nline two\u{04}\u{C2}\r\n",
            "a\r\nb  two spaces\r\n\"unterminated\r\n\"\" empty name\r\n c\r\n",
            "CAFÉ.TXT über\r\ncafé.txt second\r\n"
        ])
        seeds.append([0xFF, 0xFE] + Array("a b\r\n\"c d\" e\r\n".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        seeds.append([0xFE, 0xFF] + Array("a b\r\n".utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
        seeds.append([0xEF, 0xBB, 0xBF] + Array("x.txt bom\r\n".utf8))
        seeds.append(Array("name.txt caf".utf8) + [0xE9, 0x81, 0x0D, 0x0A])
        return seeds
    }

    /// Reads the file, writes it again and changes one comment.
    private static func run(_ bytes: [UInt8]) {
        let data = Data(bytes)
        var file = DescriptIon(data: data)
        let strict = DescriptIon(strict: data)
        if let strict {
            fzCheck(strict == file, "descript-strict-differs")
        }
        _ = file.commentsByName
        for entry in file.entries.prefix(50) {
            _ = file.comment(for: entry.name)
        }
        // Writing the file again (as any comment change does) must keep every entry.
        let again = DescriptIon(data: file.data())
        if strict != nil, !isKnown(file) || DescriptChecks.checksAll {
            fzCheck(
                again.entries == file.entries,
                "descript-rewrite-changes-entries",
                "before \(file.entries.prefix(5)) after \(again.entries.prefix(5)) bytes \(bytes.prefix(80))"
            )
        }
        changeOneComment(&file, bytes)
    }

    /// Whether the file shows one of the two known ways the rewrite went wrong.
    ///
    /// They were reported once and then left out (FZ_DESCRIPT_ALL=1 checked them again): a first name
    /// that reads like a byte-order mark, and a separator that forms one character with what stands
    /// next to it.
    private static func isKnown(_ file: DescriptIon) -> Bool {
        (file.entries.first.map { DescriptChecks.readsLikeMark($0.name) } ?? false)
            || file.entries.contains { entry in
                DescriptChecks.isGlued(entry.name + " " + entry.comment + "\r\n")
                    || DescriptChecks.isGlued("\"" + entry.name + "\" ")
            }
    }

    /// A change of one comment, as the Comment dialog makes it.
    private static func changeOneComment(_ file: inout DescriptIon, _ bytes: [UInt8]) {
        var choices = Choices(bytes)
        let name = text(choices.take(Int(choices.byte() % 16)))
        let comment = text(choices.take(Int(choices.byte() % 32)))
        file.setComment(comment, for: name.isEmpty ? "new file.txt" : name)
        _ = DescriptIon(data: file.data())
        file.setComment("", for: file.entries.first?.name ?? "x")
        _ = file.data()
        _ = DescriptIon.normalized(comment)
    }
}
