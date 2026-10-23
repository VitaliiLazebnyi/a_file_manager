import Foundation
import FuzzCore

@testable import AFMKernel

/// The folder every made-up item lives in.
internal let kDirectory = URL(fileURLWithPath: "/fuzz/dir")

/// Names that have broken sorting, matching or comparing somewhere.
internal let kTrickyNames: [String] = [
    "a", "A", "a.txt", "A.TXT", "b.txt", "é", "e\u{301}", "É", "ｅ", "", ".", "..", ".hidden", "name.", "a.b.c", "a b",
    " a", "a ", "ß", "SS", "ss", "İ", "i", "I", "ı",
    "file10", "file9", "file09", "File10.TXT", String(repeating: "x", count: 300),
    String(repeating: "é", count: 200) + ".e\u{301}", "😀.png", "👨‍👩‍👧.jpg", "\u{0}", "a\u{0}b",
    "a\u{301}\u{302}\u{303}", "\u{FFFD}", "\u{FEFF}a", "a\u{200D}", "\u{202E}txt.exe", "가", "\u{1100}\u{1161}", "ǆ",
    "Ǆ", "ǅ", "ﬁ", "fi", "Å", "\u{212B}", "\u{F900}", "\u{8C48}",
    lone([0xD800]), lone([0x61, 0xDC00, 0x62]), lone([0xD83D]), lone([0xDE00, 0xD83D]), "~", "_", "-", "!", "0", "00",
    "a-b", "a_b", "ab", "a.B", "a.b", "Z", "z", "Ω", "ω"
]

/// Sizes, the edges of `Int64` included.
internal let kSizes: [Int64] = [0, 1, 2, 1_000, 1 << 32, .max, .max - 1, 1 << 62, 5, 5, 5]

/// Dates, the infinite and the tiny ones included.
internal let kDates: [Date] = [
    Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 1_600_000_000), .distantPast, .distantFuture,
    Date(timeIntervalSinceReferenceDate: 0),
    Date(timeIntervalSinceReferenceDate: -0.0), Date(timeIntervalSinceReferenceDate: .infinity),
    Date(timeIntervalSinceReferenceDate: -.infinity),
    Date(timeIntervalSinceReferenceDate: 1e-300), Date(timeIntervalSinceReferenceDate: -1e-300),
    Date(timeIntervalSince1970: 1_600_000_000.5), Date(timeIntervalSince1970: -1)
]

/// Text from fuzz bytes: mostly UTF-8 as it comes; invalid sequences become U+FFFD (`fzText`).
internal func text(_ bytes: [UInt8]) -> String {
    fzText(bytes)
}

/// A string from UTF-16 code units, lone surrogates included (the system repairs them to U+FFFD).
internal func lone(_ units: [UInt16]) -> String {
    String(utf16CodeUnits: units, count: units.count)
}

/// A name for the next item: a tricky one, bytes from the input, or a form of the previous name.
internal func nextName(_ choices: inout Choices, previous: String?) -> String {
    switch choices.int(8) {
    case 0, 1, 2:
        return kTrickyNames[choices.int(kTrickyNames.count)]

    case 3:
        return text(choices.take(Int(choices.byte()) % 24))

    case 4:
        return previous ?? "dup"

    case 5:
        return (previous ?? "é").decomposedStringWithCanonicalMapping

    case 6:
        return (previous ?? "e\u{301}").precomposedStringWithCanonicalMapping

    default:
        let base = kTrickyNames[choices.int(kTrickyNames.count)]
        return choices.bool() ? base.uppercased() : base + "." + kTrickyNames[choices.int(kTrickyNames.count)]
    }
}

/// One item: a flags byte, a name choice, sometimes the name's own bytes.
internal func nextItem(_ choices: inout Choices, previous: String?, allowNaN: Bool) -> FileItem {
    let flags = choices.byte()
    var name = nextName(&choices, previous: previous)
    if flags & 0x40 != 0, name.utf16.count < 40 {
        name = lone(Array(name.utf16) + [0xD800 + UInt16(choices.byte())])
    }
    var modified = kDates[choices.int(kDates.count)]
    if allowNaN, flags & 0x80 != 0, choices.int(4) == 0 {
        modified = Date(timeIntervalSinceReferenceDate: .nan)
    }
    let isDirectory = flags & 3 == 0
    var item = FileItem(
        url: kDirectory.appendingPathComponent(name.isEmpty ? "_" : name),
        name: name,
        kind: .init(isDirectory: isDirectory, isPackage: isDirectory && flags & 4 != 0, isHidden: flags & 8 != 0),
        stat: .init(size: kSizes[choices.int(kSizes.count)], modified: modified)
    )
    item.computedSize = flags & 0x30 == 0x30 ? kSizes[choices.int(kSizes.count)] : nil
    return item
}

/// Up to `max` items; with `FuzzState.uniqueNames` none has the bytes of a name of another or of `besides`.
@MainActor
internal func nextItems(_ choices: inout Choices, max: Int, besides: [FileItem]) -> [FileItem] {
    var out: [FileItem] = []
    var seen = Set(besides.map { Array($0.name.utf8) })
    let count = choices.int(max)
    for _ in 0..<count where !choices.atEnd {
        let item = nextItem(&choices, previous: out.last?.name, allowNaN: false)
        if FuzzState.uniqueNames, !seen.insert(Array(item.name.utf8)).inserted {
            continue
        }
        out.append(item)
    }
    return out
}

/// A sort order: a key and a direction.
internal func nextOrder(_ choices: inout Choices) -> ListOrder {
    ListOrder(key: [SortKey.unsorted, .name, .ext, .size, .date][choices.int(5)], descending: choices.bool())
}

/// The first 40 items for a report: folder mark, name as UTF-16 in hex, size and date.
internal func describe(_ items: [FileItem]) -> String {
    items.prefix(40).map(describeItem).joined(separator: ", ")
}

/// One item for a report.
internal func describeItem(_ item: FileItem) -> String {
    let units = Array(item.name.utf16).map { String($0, radix: 16) }.joined(separator: " ")
    return "\(item.isFolder ? "[D]" : "")\(units)|\(item.size)|\(item.modified.timeIntervalSinceReferenceDate)"
}

/// The items with their position in the input as their url.
///
/// Identity of an entry in a result: the object it came from is not kept, so the position in the
/// input stands for it. Nothing in the order looks at the url.
internal func tagged(_ items: [FileItem]) -> [FileItem] {
    items.enumerated()
        .map { index, item in
            var entry = FileItem(
                url: URL(fileURLWithPath: "/i/\(index)"),
                name: item.name,
                kind: .init(isDirectory: item.isDirectory, isPackage: item.isPackage, isHidden: item.isHidden),
                stat: .init(size: item.size, modified: item.modified)
            )
            entry.computedSize = item.computedSize
            return entry
        }
}

/// The input positions of tagged items.
internal func ids(_ items: [FileItem]) -> [Int] {
    items.map { Int($0.url.lastPathComponent) ?? -1 }
}
