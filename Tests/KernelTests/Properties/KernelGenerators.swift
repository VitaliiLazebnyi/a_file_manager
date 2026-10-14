import Foundation
import TestSupport

@testable import AFMKernel

/// Generators of the kernel's values for the property tests.
internal enum KernelGenerators {
    /// Pieces of names: plain letters and digits, case pairs, an accent written in one character
    /// and in two, letters whose case forms differ in length (`ß`), Cyrillic letters that the
    /// system's comparison once ordered both ways round, a picture, a ligature, the Kelvin sign,
    /// a lone accent, control characters, the dot and the mask characters.
    internal static let namePieces: [String] = [
        "a", "b", "A", "B", "z", "0", "1", "9", "10", ".", " ", "_", "-", "~", "\u{E9}", "e\u{301}", "E\u{301}",
        "\u{DF}", "ss", "SS", "\u{E4}", "\u{438}", "\u{439}", "\u{418}\u{306}", "\u{451}", "\u{435}\u{308}",
        "\u{1F600}", "\u{FB01}", "\u{212A}", "k", "\u{131}", "\u{130}", "\u{301}", "*", "?", "\u{1}", "\u{FFFD}"
    ]

    /// File names, the empty one included.
    internal static let name = Generate.text(from: namePieces, lengths: 0...8)

    /// Names from few pieces, so that a list often holds a name twice or differing only in case.
    internal static let crowdedName = Generate.text(from: ["a", "A", ".", "b", "\u{E9}", "e\u{301}"], lengths: 0...3)

    /// Dates of last change: ordinary ones, the same ones twice, and the odd values a file system
    /// or an archive can report (not a number, infinities, minus zero).
    internal static let date = Generate.oneOf([
        Generate.int(in: 0...5).map { Date(timeIntervalSinceReferenceDate: Double($0) * 1_000) },
        Generate.element(of: [Double.nan, .infinity, -.infinity, -0.0, -1e300])
            .map { interval in Date(timeIntervalSinceReferenceDate: interval) }
    ])

    /// A size: small ones, so that sizes repeat, and any number of 64 bits.
    internal static let size = Generate.oneOf([Generate.int(in: 0...3).map { Int64($0) }, Generate.int64])

    /// The ways a list can be ordered.
    internal static let order = Generate.element(of: [SortKey.name, .ext, .size, .date, .unsorted])
        .flatMap { key in
            Generate.bool.map { ListOrder(key: key, descending: $0) }
        }

    /// Lists of entries, each at a location of its own (its place in the list), so that a test
    /// can tell entries of the same name apart.
    internal static func items(_ names: Generator<String>, lengths: ClosedRange<Int>) -> Generator<[FileItem]> {
        entry(names).array(lengths).map { numbered($0, from: 0) }
    }

    /// One entry; its location is set by `numbered`.
    internal static func entry(_ names: Generator<String>) -> Generator<FileItem> {
        names.flatMap { name in
            Generate.int(in: 0...5)
                .flatMap { kind in
                    size.flatMap { size in
                        date.map { date in
                            FileItem(
                                url: URL(fileURLWithPath: "/"),
                                name: name,
                                kind: .init(isDirectory: kind < 2, isPackage: kind == 1),
                                stat: .init(size: size, modified: date)
                            )
                        }
                    }
                }
        }
    }

    /// The entries, each moved to a location that holds its place in the list.
    internal static func numbered(_ items: [FileItem], from first: Int) -> [FileItem] {
        items.enumerated()
            .map { place, item in
                FileItem(
                    url: URL(fileURLWithPath: "/list/\(first + place)"),
                    name: item.name,
                    kind: .init(isDirectory: item.isDirectory, isPackage: item.isPackage),
                    stat: .init(size: item.size, modified: item.modified)
                )
            }
    }

    /// Many entries with simple names, quickly made: for the paths that work on all cores, which
    /// lists of more than `ListWork.pieceSize * 2` entries take.
    internal static func longList(count: Int) -> Generator<[FileItem]> {
        Generator { choices in
            numbered(
                (0..<count)
                    .map { _ in
                        let word = choices.nextWord()
                        let letters = ["a", "B", "\u{E9}", "c", ".", "1"]
                        let text = (0..<Int(word % 4)).map { letters[Int(word >> (8 + $0 * 3)) % letters.count] }
                            .joined()
                        return FileItem(
                            url: URL(fileURLWithPath: "/"),
                            name: text,
                            kind: .init(isDirectory: (word >> 40).isMultiple(of: 4)),
                            stat: .init(
                                size: Int64((word >> 44) % 8),
                                modified: Date(timeIntervalSinceReferenceDate: Double((word >> 50) % 4))
                            )
                        )
                    },
                from: 0
            )
        }
    }
}
