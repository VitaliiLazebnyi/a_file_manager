import Foundation
import FuzzCore

@testable import AFMKernel
@testable import CompareContentPlugin
@testable import FileOperationsPlugin
@testable import MultiRenamePlugin

// Group 7: CompareContent (Myers, TextDiff, inline highlights, the loader's decoding, BinaryDiff),
// MultiRename (RenameMask, RenameRules, RenamePlanner), FileOperations NameTemplate.

func text(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
func seedsOf(_ s: [String]) -> [[UInt8]] { s.map { Array($0.utf8) } }

/// Length of the longest common subsequence, the plain quadratic way.
func lcs<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
    guard !a.isEmpty, !b.isEmpty else { return 0 }
    var row = [Int](repeating: 0, count: b.count + 1)
    for x in a {
        var diagonal = 0
        for j in 0..<b.count {
            let above = row[j + 1]
            row[j + 1] = x == b[j] ? diagonal + 1 : max(above, row[j])
            diagonal = above
        }
    }
    return row[b.count]
}

func checkSegments<T: Equatable>(
    _ s: [DiffSegment], _ a: [T], _ b: [T], _ key: String, _ detail: @autoclosure () -> String
) {
    var (i, j) = (0, 0)
    for seg in s {
        fzCheck(seg.a.lowerBound == i && seg.b.lowerBound == j, key + "-cover", detail())
        fzCheck(!(seg.a.isEmpty && seg.b.isEmpty), key + "-empty-segment", detail())
        if seg.isEqual {
            fzCheck(
                seg.a.count == seg.b.count && seg.a.upperBound <= a.count && seg.b.upperBound <= b.count
                    && Array(a[seg.a]) == Array(b[seg.b]), key + "-equal-not-equal", detail())
        }
        (i, j) = (seg.a.upperBound, seg.b.upperBound)
    }
    fzCheck(i == a.count && j == b.count, key + "-cover-end", detail())
    fzCheck(Myers.apply(s, to: a, from: b) == b, key + "-apply", detail())
}

// MARK: myers

let myers = FuzzTarget(
    "myers", maxLen: 1 << 15,
    seeds: {
        [
            [4, 0, 0] + Array("abcabba".utf8) + [0xFF] + Array("cbabac".utf8),
            [2, 3, 0] + Array("aabbaabbabab".utf8) + [0xFF] + Array("babababbbaaa".utf8),
            [3, 1, 0x85] + Array("abcabcaabbcc".utf8) + [0xFF] + Array("ccbbaacbacba".utf8),
            [1, 0, 0] + Array("aaaa".utf8) + [0xFF], [5, 2, 0x10, 0xFF, 1, 2, 3]
        ]
    },
    run: { bytes in
        var c = Choices(bytes)
        let alphabet = 1 + Int(c.byte()) % 7
        let l = Int(c.byte())
        let limit: Int? = l % 4 == 0 ? nil : (l >> 2) % 24
        let r = c.byte()
        let times = r & 0x80 != 0 ? 1 + Int(r & 0x3F) : 1
        let one = c.until(0xFF).map { Int($0) % alphabet }
        let two = c.rest().map { Int($0) % alphabet }
        var a: [Int] = []
        var b: [Int] = []
        for k in 0..<times {
            a += one
            b += (k % 3 == 2 ? two.reversed() : two)
        }
        let d =
            "alphabet \(alphabet) limit \(String(describing: limit)) a=\(a.prefix(80)) b=\(b.prefix(80)) (\(a.count),\(b.count))"
        let s = Myers.diff(a, b, costLimit: limit)
        checkSegments(s, a, b, "myers", d)
        if a.count * b.count <= 60_000 {
            let best = a.count + b.count - 2 * lcs(a, b)
            let got = Myers.editDistance(s)
            fzCheck(got >= best, "myers-distance-below-optimum", d)
            if limit == nil { fzCheck(got == best, "myers-not-shortest", d + " got \(got) best \(best)") }
        }
        // the UTF-16 overload
        let (ua, ub) = (a.map { UInt16($0 &* 9_973 & 0xFFFF) }, b.map { UInt16($0 &* 9_973 & 0xFFFF) })
        if ua.count + ub.count <= 4_000 { checkSegments(Myers.diff(ua, ub, costLimit: limit), ua, ub, "myers16", d) }
    })

// MARK: textdiff

func splitPair(_ c: inout Choices) -> ([UInt8], [UInt8]) {
    let all = c.rest()
    var i = 0
    while i + 1 < all.count {
        if all[i] == 0x1C, all[i + 1] == 0x1D { return (Array(all[..<i]), Array(all[(i + 2)...])) }
        i += 1
    }
    return (all, [])
}
let sep: [UInt8] = [0x1C, 0x1D]

let textDiff = FuzzTarget(
    "textdiff", maxLen: 1 << 14,
    dict: [
        "\r\n", "\r", "\n", " ", "\t", "a\n", "A\n", "é", "e\u{301}", "\u{212A}", "K", "k", "\u{1C}\u{1D}", "  a  b\n",
        "a b\n"
    ],
    rawDict: [[0xEF, 0xBB, 0xBF], [0xFF, 0xFE], [0xFE, 0xFF], [0xD8, 0x00], [0x00, 0xDC]],
    seeds: {
        [
            [7, 0] + Array("one\ntwo\nthree\nfour\n".utf8) + sep + Array("one\nTWO\nthree\nfive\nfour".utf8),
            [0, 1, 3, 3] + Array("a\r\nb\rc\n a  b \nx\n".utf8) + sep + Array("a\nb\nc\na b\ny\nx\n".utf8),
            [0x35, 2, 2, 2, 5, 4] + Array("a\nb\na\nb\na\nb\nc\n".utf8) + sep + Array("b\na\nb\na\nc\na\nb\n".utf8),
            [3, 0, 0xFF, 0xFE] + Array("a\0\n\0b\0\n\0".utf8) + sep + [0xFE, 0xFF] + Array("\0a\0\n\0c\0\n".utf8),
            [1, 0] + Array("é\ne\u{301}\nK\n".utf8) + sep + Array("e\u{301}\nÉ\n\u{212A}\n".utf8)
        ]
    },
    run: { bytes in
        var c = Choices(bytes)
        let f = c.byte()
        let options = DiffOptions(
            ignoreCase: f & 1 != 0, ignoreRepeatedSpaces: f & 2 != 0, ignoreLineEndings: f & 4 != 0)
        let limit: Int? = f & 0x30 == 0x30 ? Int(f >> 6) : nil
        let anchorCount = Int(c.byte()) % 4
        var anchors: [(left: Int, right: Int)] = []
        for _ in 0..<anchorCount { anchors.append((Int(c.byte()) - 2, Int(c.byte()) - 2)) }
        let (lb, rb) = splitPair(&c)
        let (ld, rd) = (TextDocument(data: Data(lb)), TextDocument(data: Data(rb)))
        let (left, right) = (ld.lines, rd.lines)
        let d =
            "options \(options) limit \(String(describing: limit)) anchors \(anchors) left \(left.map { $0.text + $0.ending.rawValue }.prefix(40).debugDescription) right \(right.map { $0.text + $0.ending.rawValue }.prefix(40).debugDescription)"
        let diff = TextDiff.compute(left: left, right: right, options: options, anchors: anchors, costLimit: limit)
        var (i, j) = (0, 0)
        for row in diff.rows {
            switch row.kind {
            case .equal, .changed:
                fzCheck(row.left == i && row.right == j, "textdiff-rows-order", d)
                if row.kind == .equal, let x = row.left, let y = row.right, x < left.count, y < right.count {
                    fzCheck(options.isSameKey(left[x], right[y]), "textdiff-equal-row-differs", d)
                }
                i += 1
                j += 1

            case .added:
                fzCheck(row.left == nil && row.right == j, "textdiff-rows-order", d)
                j += 1

            case .removed:
                fzCheck(row.right == nil && row.left == i, "textdiff-rows-order", d)
                i += 1
            }
        }
        fzCheck(i == left.count && j == right.count, "textdiff-rows-cover", d)
        fzCheck(
            diff.rebuiltRight(left: Array(left.indices), right: Array(right.indices)) == Array(right.indices),
            "textdiff-rebuilt", d)
        var inBlock = [Bool](repeating: false, count: diff.rows.count)
        var last = -1
        for block in diff.blocks {
            fzCheck(
                !block.isEmpty && block.lowerBound > last && block.upperBound <= diff.rows.count, "textdiff-blocks", d
            )
            for r in block { inBlock[r] = true }
            last = block.upperBound
        }
        for (r, row) in diff.rows.enumerated() {
            fzCheck((row.kind != .equal) == inBlock[r], "textdiff-blocks-kind", d)
        }
        if anchors.isEmpty, limit == nil, left.count * right.count <= 20_000 {
            let (ka, kb) = (left.map(options.key), right.map(options.key))
            let equal = diff.rows.filter { $0.kind == .equal }.count
            fzCheck(equal == lcs(ka, kb), "textdiff-not-shortest", d + " equal rows \(equal) lcs \(lcs(ka, kb))")
        }
        if case .text(_, _, let again, let width) = CompareLoader.text(
            left: ld, right: rd, options: options, anchors: anchors)
        {
            fzCheck(width == (left + right).reduce(0) { max($0, $1.text.utf16.count) }, "comparetext-width", d)
            if limit == nil { fzCheck(again == diff, "comparetext-differs", d) }
        } else {
            fzFail("comparetext-kind", d)
        }
    })

// MARK: inline

func removing(_ ranges: [Range<Int>], from units: [UInt16]) -> [UInt16] {
    var out: [UInt16] = []
    var at = 0
    for r in ranges {
        out += units[at..<r.lowerBound]
        at = r.upperBound
    }
    return out + units[at...]
}

func utf16Pair(_ c: inout Choices, wide: Bool) -> ([UInt16], [UInt16]) {
    let (lb, rb) = splitPair(&c)
    func units(_ b: [UInt8]) -> [UInt16] {
        if !wide { return Array(String(decoding: b, as: UTF8.self).utf16) }
        return stride(from: 0, to: b.count - 1, by: 2).map { UInt16(b[$0]) | UInt16(b[$0 + 1]) << 8 }
    }
    return (units(lb), units(rb))
}

let inline = FuzzTarget(
    "inline", maxLen: 24_000,
    dict: [
        "e\u{301}", "é", "👍🏽", "👨‍👩‍👧", "\u{200D}", "\u{FE0F}", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "\u{1C}\u{1D}"
    ],
    rawDict: [[0x3D, 0xD8], [0x4D, 0xDC], [0x00, 0xD8], [0xFF, 0xDF], [0x01, 0x03]],
    seeds: {
        [
            [3, 0] + Array("The quick brown fox".utf8) + sep + Array("The quack brown box".utf8),
            [0, 0] + Array("e\u{301}a👍🏽b".utf8) + sep + Array("éa👍b".utf8),
            [
                2, 1, 0x3D, 0xD8, 0x4D, 0xDC, 0x41, 0, 0x3D, 0xD8, 0x1C, 0x1D, 0x4D, 0xDC, 0x41, 0, 0x3D, 0xD8, 0x4E,
                0xDC
            ],
            [3, 0] + Array((String(repeating: "x", count: 40) + "abc" + String(repeating: "y", count: 40)).utf8) + sep
                + Array((String(repeating: "x", count: 40) + "abd" + String(repeating: "y", count: 40)).utf8),
            [3, 0x80] + Array("abcdefgh".utf8) + sep + Array("abxdefgy".utf8)
        ]
    },
    run: { bytes in
        var c = Choices(bytes)
        let minimum = Int(c.byte()) % 6
        let f = c.byte()
        var (a, b) = utf16Pair(&c, wide: f & 1 != 0)
        if f & 0x80 != 0 {  // long lines, beyond the inline limit
            let times = 1 + Int(f >> 1 & 0x3F) * 20
            if a.count * times <= 12_000 { a = Array(repeatElement(a, count: times).joined()) }
            if b.count * (times + 1) <= 12_000 { b = Array(repeatElement(b, count: times + 1).joined()) }
        }
        // As the window has them: lines that came out of a decoder (lone surrogates repaired),
        // and bridged strings, which may still carry them.
        for bridged in [false, true] {
            let (l, r): (String, String) =
                bridged
                ? (
                    NSString(characters: a, length: a.count) as String,
                    NSString(characters: b, length: b.count) as String
                )
                : (String(decoding: a, as: UTF16.self), String(decoding: b, as: UTF16.self))
            let (ua, ub) = (Array(l.utf16), Array(r.utf16))
            let d =
                "minimumMatch \(minimum) bridged \(bridged) left \(ua.prefix(60)) right \(ub.prefix(60)) (\(ua.count),\(ub.count))"
            let h = TextDiff.inline(l, r, minimumMatch: minimum)
            for (ranges, count) in [(h.left, ua.count), (h.right, ub.count)] {
                var end = -1
                for range in ranges {
                    fzCheck(
                        !range.isEmpty && range.lowerBound > end && range.upperBound <= count, "inline-ranges-invalid",
                        d + " ranges \(ranges)")
                    end = range.upperBound
                }
            }
            // The marks cover whole characters (a surrogate pair, a letter with its accents), so one side may mark
            // more than the other: what is left unmarked on one side still stands, in that order, in the other line.
            func isSubsequence(_ part: [UInt16], of whole: [UInt16]) -> Bool {
                var at = 0
                for unit in whole where at < part.count && part[at] == unit { at += 1 }
                return at == part.count
            }
            fzCheck(
                isSubsequence(removing(h.left, from: ua), of: ub)
                    && isSubsequence(removing(h.right, from: ub), of: ua), "inline-rest-differs", d + " \(h)")
            // No mark cuts a character in two (the lines as the window holds them: lone surrogates repaired).
            if !bridged {
                for (ranges, text) in [(h.left, l as NSString), (h.right, r as NSString)] {
                    for range in ranges where range.upperBound <= text.length {
                        let whole = text.rangeOfComposedCharacterSequences(
                            for: NSRange(location: range.lowerBound, length: range.count))
                        fzCheck(
                            whole.location == range.lowerBound && whole.length == range.count,
                            "inline-mark-cuts-a-character", d + " range \(range) whole \(whole)")
                    }
                }
            }
            if l == r, ua == ub { fzCheck(h.left.isEmpty && h.right.isEmpty, "inline-equal-highlighted", d) }
        }
    })

// MARK: loader (decoding into lines, binary comparison)

let loader = FuzzTarget(
    "loader", maxLen: 1 << 14,
    dict: ["\r\n", "\r", "\n", "\u{2028}", "\u{85}", "\u{1C}\u{1D}"],
    rawDict: [
        [0xEF, 0xBB, 0xBF], [0xFF, 0xFE], [0xFE, 0xFF], [0x00, 0xD8], [0xD8, 0x00], [0x0D, 0x00, 0x0A, 0x00], [0xC3],
        [0xE2, 0x80], [0xF0, 0x9F], [0], [0x0A, 0x00]
    ],
    seeds: {
        [
            [16] + Array("one\r\ntwo\rthree\nfour".utf8) + sep + Array("one\ntwo\n".utf8),
            [0, 0xEF, 0xBB, 0xBF] + Array("bom\nline\n".utf8) + sep + [0xFF, 0xFE, 0x61, 0, 0x0D, 0, 0x0A, 0, 0x62, 0],
            [3, 0xFE, 0xFF, 0, 0x61, 0, 0x0A, 0xD8, 0x3D, 0xDC, 0x4D] + sep + [0xE9, 0x0A, 0x80, 0x0D],
            [200, 1, 2, 0, 3] + sep + [1, 2, 3, 3, 4, 5]
        ]
    },
    run: { bytes in
        var c = Choices(bytes)
        let per = Int(Int8(bitPattern: c.byte()))
        let (lb, rb) = splitPair(&c)
        for raw in [lb, rb] {
            let data = Data(raw)
            let document = TextDocument(data: data)
            let d = "bytes \(raw.prefix(64)) (\(raw.count)) encoding \(document.encoding.name)"
            fzCheck(document.encoding == TextEncoding.detect(data), "loader-detect-differs", d)
            for (n, line) in document.lines.enumerated() {
                fzCheck(line.number == n + 1, "loader-line-number", d)
                fzCheck(!line.text.utf8.contains(0x0A) && !line.text.utf8.contains(0x0D), "loader-break-in-line", d)
                fzCheck(line.ending != .none || n == document.lines.count - 1, "loader-ending-inside", d)
            }
            _ = document.usualEnding
            // "The file's bytes: the same as were loaded as long as nothing was changed" - where
            // the bytes are valid in the encoding that was found.
            let body = data.dropFirst(document.encoding.bom.count)
            let strict: String?
            switch document.encoding {
            case .utf8: strict = String(data: body, encoding: .utf8)
            case .latin1: strict = String(data: body, encoding: .isoLatin1)
            case .utf16LittleEndian: strict = String(data: body, encoding: .utf16LittleEndian)
            case .utf16BigEndian: strict = String(data: body, encoding: .utf16BigEndian)
            }
            if let strict,
                strict.data(
                    using: document.encoding == .latin1
                        ? .isoLatin1
                        : document.encoding == .utf16LittleEndian
                            ? .utf16LittleEndian
                            : document.encoding == .utf16BigEndian ? .utf16BigEndian : .utf8) == Data(body)
            {
                fzCheck(
                    document.data() == data, "loader-roundtrip", d + " back \([UInt8](document.data()).prefix(64))")
            } else {
                _ = document.data()
            }
            _ = TextDocument.looksBinary(data)
            // a forced encoding, as the encoding menu asks for
            for encoding in [
                TextEncoding.utf8(bom: false), .utf8(bom: true), .utf16LittleEndian, .utf16BigEndian, .latin1
            ] {
                let forced = TextDocument(data: data, encoding: encoding)
                _ = forced.data()
            }
        }
        let (l, r) = (Data(lb), Data(rb))
        let diff = BinaryDiff.compute(left: l, right: r, bytesPerLine: per)
        let d = "bytesPerLine \(per) left \(lb.prefix(48)) right \(rb.prefix(48))"
        var differing = abs(l.count - r.count)
        for k in 0..<min(l.count, r.count) where lb[k] != rb[k] { differing += 1 }
        fzCheck(diff.differingBytes == differing, "binarydiff-count", d)
        var marked = Set<Int>()
        for block in diff.blocks {
            fzCheck(!block.isEmpty && block.upperBound <= diff.rowCount, "binarydiff-blocks", d)
            block.forEach { marked.insert($0) }
        }
        for row in 0..<min(diff.rowCount + 1, 3_000) {
            let offsets = diff.differingOffsets(left: l, right: r, row: row)
            fzCheck(offsets.isEmpty != marked.contains(row), "binarydiff-row", d + " row \(row)")
            let line = diff.text(of: l, row: row)
            _ = diff.text(of: r, row: row)
            _ = diff.offsetText(row: row)
            for o in offsets {
                for range in diff.textRanges(ofByte: o) where o < l.count - row * diff.bytesPerLine {
                    fzCheck(
                        range.upperBound <= line.utf16.count, "binarydiff-textrange", d + " row \(row) offset \(o)")
                }
            }
        }
    })

// MARK: rename mask / rules

let realisticDates: [Double] = [
    0, 1_700_000_000, 1_700_000_000.789, -62_167_219_200, 253_402_300_799, -1, 951_782_400, 4_102_444_800, 1e10, -1e10,
    86_399.9999
]
let utc = TimeZone(identifier: "UTC")!
let enUS = Locale(identifier: "en_US_POSIX")

func name255(_ b: [UInt8]) -> String {
    var s = text(b)
    while s.utf8.count > 255 { s.removeLast() }
    return s
}

func renameCase(_ c: inout Choices, regex: Bool) -> (RenameSettings, RenameContext, RenameSubject, Int, String?) {
    let f = c.byte()
    let g = c.byte()
    var settings = RenameSettings()
    settings.caseSensitive = f & 1 != 0
    settings.firstOnly = f & 2 != 0
    settings.searchesExtension = f & 4 != 0
    settings.regularExpression = regex
    settings.substitute = f & 8 != 0
    settings.letterCase = LetterCase(rawValue: Int(f >> 4) % 6) ?? .unchanged
    func number(_ c: inout Choices) -> Int {
        let k = c.byte()
        switch k % 8 {
        case 0: return Int(c.byte())
        case 1: return -Int(c.byte())
        case 2: return Int(truncatingIfNeeded: c.u64())
        case 3: return Int.max
        case 4: return Int.min
        case 5: return Int(c.u16())
        default: return Int(k >> 3)
        }
    }
    settings.counter = CounterDefinition(start: number(&c), step: number(&c), digits: number(&c))
    var context = RenameContext()
    // the number of items in the list: never negative, and no list is longer than a few million
    context.count = g & 1 != 0 ? Int(c.u32() % 3_000_000) : 1 + Int(c.byte())
    let index = g & 2 != 0 ? abs(number(&c) % 1_000_000) : Int(c.byte())
    context.opened = Date(timeIntervalSince1970: 1_700_000_000)
    context.changed = Date(timeIntervalSince1970: 1_700_003_600)
    context.locale = enUS
    context.timeZone = utc
    context.environment = ["HOME": "/Users/me", "X": "a:b/c\\d", "E": "", "é": "ü"]
    let date = realisticDates[Int(c.byte()) % realisticDates.count]
    context.contentDate =
        g & 4 != 0 ? { _ in Date(timeIntervalSince1970: date + 1) } : (g & 8 != 0 ? { _ in nil } : nil)
    let size = Int64(truncatingIfNeeded: number(&c))
    settings.nameMask = text(c.until(0x0A))
    settings.extensionMask = text(c.until(0x0A))
    settings.search = text(c.until(0x0A))
    settings.replacement = text(c.until(0x0A))
    let name = name255(c.until(0x0A))
    let directory = text(c.until(0x0A))
    let clip = c.until(0x0A)
    context.clipboard = g & 16 != 0 ? nil : text(clip).replacingOccurrences(of: "\u{1}", with: "\n")
    let rule = c.until(0x0A)
    if g & 32 != 0 { context.titleRule = TitleCaseRule(setting: text(rule)) }
    let given: String? = g & 64 != 0 ? text(c.until(0x0A)) : nil
    let subject = RenameSubject(
        name: name, isFolder: g & 128 != 0, size: size, modified: Date(timeIntervalSince1970: date),
        directoryPath: directory)
    return (settings, context, subject, index, given)
}

var slowestRename = 0.0
func runRename(_ bytes: [UInt8], regex: Bool) {
    var c = Choices(bytes)
    let (settings, context, subject, index, given) = renameCase(&c, regex: regex)
    let t = Date()
    let engine = RenameEngine(settings, context: context)
    let name = engine.newName(for: subject, index: index, given: given)
    _ = engine.newName(for: subject, index: 0)
    let dt = Date().timeIntervalSince(t)
    if dt > slowestRename, dt > 0.005 {
        slowestRename = dt
        fzNote(
            "rename slowest \(Int(dt * 1_000)) ms search=\(settings.search.debugDescription.prefix(160)) name=\(subject.name.debugDescription.prefix(120)) mask=\(settings.nameMask.debugDescription.prefix(120))"
        )
    }
    if let name {
        _ = RenameEngine.invalidity(of: name)
        fzCheck(
            !name.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }, "rename-control-character-left",
            name.debugDescription)
        fzCheck(RenameEngine.tidied(name) == name, "rename-tidy-unstable", name.debugDescription)
    }
    // the masks on their own, with the state carried from name to extension
    let formats = RenameFormats(locale: enUS, timeZone: utc)
    var state = MaskState()
    for maskText in [settings.nameMask, settings.extensionMask, settings.search] {
        let mask = RenameMask(maskText)
        _ = mask.error
        _ = try? mask.evaluate(subject, index: index, context: engine.context, formats: formats, state: &state)
        for case .text(_, let range?) in mask.tokens {
            _ = range.apply(to: subject.name)
            _ = range.apply(to: "")
        }
    }
    for letterCase in LetterCase.allCases {
        _ = letterCase.apply(to: subject.name, rule: context.titleRule)
        _ = letterCase.apply(to: settings.replacement)
    }
    _ = try? RenameMask.alphabetic(
        String(settings.replacement.prefix(40).filter { $0.isASCII && $0.isLetter }), advancedBy: index)
    _ = SearchReplace.wildcardPattern(settings.search)
    _ = SearchReplace.systemPattern(settings.search)
}

let maskDict = [
    "[N]", "[E]", "[A]", "[P]", "[G]", "[S]", "[C]", "[C10+5:3]", "[C+1/100]", "[Caa+1]", "[CZZ-3]", "[C:a]", "[c]",
    "[c2]", "[c3]", "[YMD]", "[hms]",
    "[d]", "[t]", "[i1]", "[v]", "[T1]", "[T2+999999999Y]", "[T3-999999999M]", "[T4]", "[T1+5D]", "[U]", "[L]", "[F]",
    "[f]", "[n]", "[u]", "[I]", "[I1]",
    "[X]", "[X+]", "[%HOME%]", "[%X%\\]", "[%X%_]", "[%HOME%2-5]", "[B1]", "[B+2_1-3]", "[N2-5]", "[N2,3]", "[N-8-5]",
    "[N02-9]", "[N 1,999999999]",
    "[-999999999-999999999]", "[N999999999-]", "[[]", "[]]", "[", "]", "[=tc.size]", "999999999", "-", ",", ":", "+",
    "/", ".", "\u{301}", "ǆ", "ß", "İ", "ﬁ", "🇩🇪"
]

let renameMask = FuzzTarget(
    "renamemask", maxLen: 4_096, dict: maskDict + ["*", "?", "|", "a|b", "*.*"],
    seeds: {
        seedsOf([
            "00000000000000[N]\n[E]\n\n\nreport 2024.final.txt\n/Users/me/Docs\nclip\nx:a,b\n",
            "\u{43}\u{1}\u{9}\u{9}\u{9}\u{9}\u{9}\u{9}\u{9}\u{9}\u{9}\u{9}\u{9}\u{9}[N2-5][C10+5:3] [YMD][hms][T2+1D][d] [t]\n[U][E][Caa+1]\n a|*x|?\n_|y\n.hidden file.TAR.gz\n/a/b/c/d\nclip\n\n",
            "\u{ff}\u{ff}\u{3}\u{3}\u{4}\u{2}\u{2}\u{1}\u{2}\u{2}\u{3}\u{9}\u{9}\u{9}[f][A][c3][c2][C][B+1_2,3][%X%_][X+][I][T4][v]\n[N-8-5][[][]][G][P][S]\nA\nb\nthe lord of the rings.Mkv\n/x/y\n\nEnglish!:a,the,of\ngiven.name.ext\n"
        ])
    },
    run: { runRename($0, regex: false) })

let renameRegex = FuzzTarget(
    "renameregex", maxLen: 2_048,
    dict: maskDict.prefix(12) + [
        "(?P<n>", "(?P=n)", "(?'n'", "(?g)", "(?-g)", "^??", "$1", "$12", "\\U$1", "\\L$2", "\\F$1", "\\n$1", "$89",
        "(a+)+$", "(.*)*", "(?=", "(?<=", "\\b", "(", ")", "|", "*?", "{1,3}", "[a-z]", "\\d+", "$", "^", "\\", "(?R)",
        "(?1)", "\\K"
    ],
    seeds: {
        seedsOf([
            "00000000000000[N]\n[E]\n(\\w+) (\\d+)\n\\U$2_\\L$1 $12\nReport 2024.txt\n/d\n\n\n",
            "8000000000000 [N]\n[E]\n(?P<a>x)(?P=a)|^??b|(?'q'c)(?g)\n$1$2$3\\x\\\nxxbc.c\n/d\n\n\n",
            "00000000000000[N]\n[E]\n(a*)*b|()\n<$1>\naaaaaaaaaaaaaaaa.a\n/d\n\n\n"
        ])
    },
    run: { runRename($0, regex: true) })

// MARK: planner

let pool = ["a", "A", "b", "B", "c", "é", "e\u{301}", "a (2)", "a.txt", "A.TXT", "a (2).txt", "b.d", "x y", "É"]

let planner = FuzzTarget(
    "planner", maxLen: 256,
    seeds: {
        [
            [0, 3, 0, 2, 4, 1, 3, 2, 1, 3, 0, 0], [1, 2, 0, 1, 2, 2, 2, 1, 5, 6],
            [2, 5, 0, 1, 2, 3, 4, 2, 3, 3, 4, 3, 5, 2, 1, 4, 0, 9, 9],
            [5, 4, 8, 9, 10, 0, 2, 1, 2, 10, 2, 9, 0, 0, 3, 7, 7]
        ]
    },
    run: { bytes in
        var c = Choices(bytes)
        let f = c.byte()
        let folds = f & 1 != 0
        let mode = Int(f >> 1) % 3  // 0: as it is (when free of conflicts), 1: auto rename, 2: skip
        let n = 1 + Int(c.byte()) % 8
        let planner =
            folds
            ? RenamePlanner(foldsCase: true)
            : (f & 0x40 != 0 ? RenamePlanner(foldedFolders: ["file:///d"]) : RenamePlanner())
        let folderD = URL(fileURLWithPath: "/d", isDirectory: true)
        let folderE = URL(fileURLWithPath: "/e", isDirectory: true)
        var sources: [URL] = []
        var seen = Set<String>()
        for _ in 0..<n {
            let u = (c.byte() & 0x80 != 0 ? folderE : folderD).appending(name: pool[Int(c.byte()) % pool.count])
            if seen.insert(planner.key(u)).inserted { sources.append(u) }
        }
        var targets: [URL?] = []
        var isFolder: [Bool] = []
        for s in sources {
            let k = c.byte()
            isFolder.append(k & 0x40 != 0)
            switch k % 5 {
            case 0: targets.append(nil)
            case 1: targets.append(s)

            default:
                targets.append((k & 0x80 != 0 ? folderE : folderD).appending(name: pool[Int(c.byte()) % pool.count]))
            }
        }
        var existing = Set(sources.map(planner.key))
        for _ in 0..<(Int(c.byte()) % 4) {
            existing.insert(
                planner.key((c.byte() & 1 != 0 ? folderE : folderD).appending(name: pool[Int(c.byte()) % pool.count])))
        }
        let d =
            "folds \(folds) mode \(mode) sources \(sources.map(\.path)) targets \(targets.map { $0?.path ?? "-" }) existing \(existing.sorted())"
        var plan = targets
        if mode == 1 {
            plan = planner.autoRenamed(sources: sources, targets: targets, isFolder: isFolder, existing: existing)
        }
        if mode == 2 { plan = planner.skippingConflicts(sources: sources, targets: targets, existing: existing) }
        let conflicts = planner.conflicts(sources: sources, targets: plan, existing: existing)
        if mode != 0 {
            fzCheck(
                conflicts.isEmpty, mode == 1 ? "planner-autorename-leaves-conflict" : "planner-skip-leaves-conflict",
                d + " plan \(plan.map { $0?.path ?? "-" }) conflicts \(conflicts)")
        }
        guard conflicts.isEmpty else { return }
        // Carry the steps out on a set of names.
        var names = existing
        var place = sources.map(planner.key)
        let steps = planner.steps(sources: sources, targets: plan, temporaryName: { ".tmp-\($0)" })
        let dd =
            d
            + " plan \(plan.map { $0?.path ?? "-" }) steps \(steps.map { "\($0.item):\($0.from.path)>\($0.to.path)" })"
        for step in steps {
            let (from, to) = (planner.key(step.from), planner.key(step.to))
            fzCheck(place[step.item] == from && names.contains(from), "planner-step-source-missing", dd)
            fzCheck(step.ontoItself == (from == to), "planner-onto-itself-flag", dd)
            fzCheck(from == to || !names.contains(to), "planner-step-onto-existing", dd)
            names.remove(from)
            names.insert(to)
            place[step.item] = to
        }
        for i in sources.indices {
            let want = plan[i].map(planner.key) ?? planner.key(sources[i])
            // A change of case only on a folding file system still is a rename to carry out.
            if let t = plan[i], t.locationKey != sources[i].locationKey {
                fzCheck(place[i] == want, "planner-item-not-at-target", dd)
            } else {
                fzCheck(place[i] == planner.key(sources[i]), "planner-staying-item-moved", dd)
            }
        }
    })

// MARK: name template

var slowestTemplate = 0.0
let nameTemplate = FuzzTarget(
    "nametemplate", maxLen: 2_048,
    dict: maskDict + [
        "<", ">", "|", "\"", "<1-10>", "<0-99999>", "<1-3>test[\" (\"C\")\"]", "[\" (\"C\")\"]", "[C:3]", "[C:999]",
        "[C10+5:3]", "[Y-M-D]", "[T2+1D]", "[T1+9223372036854775807Y]",
        "[T1-9223372036854775808s]", "[N9223372036854775807-]", "[N1,9223372036854775807]", "[N-9223372036854775807-1]",
        "9223372036854775807", "[N1--1]", "[%HOME%1-2]",
        "[N01,300]", "[N 2-5]", "[i1]", "[d]", "[t]", "٣", "²", "[N٣]", "[C²]"
    ],
    seeds: {
        seedsOf([
            "00a/b/c | other\nfile.name.txt\nparent\ngrand\nclip\n",
            "10<[Y]-[M]-[D] downloads [hms][v][i][i1][d][t]\nx.y\np\ng\nc\n",
            "20<Copy of [N] [E] [A] [P] [G] [S] [N2-5] [N2,3] [N-3-] [N02-9] [N-8-5]\nreport final.tar.gz\np\ng\nc\n",
            "30<1-10>[C]\n\n\n\n\n", "40<1-3>test[\" (\"C\")\"]\n\n\n\n\n",
            "50<test[C]|a[C:3]|[U]b[L]C[F]the end of[f]the end of[n][X][X+][[][]][%HOME%]\nn\np\ng\nclip\n",
            "61\"a b.txt\" \"c.txt\" d|e\n\n\n\n\n", "70<[T2+1D][Y][T1-60m][h][=x][Q][N\n\n\n\n\n"
        ])
    },
    run: { bytes in
        var c = Choices(bytes)
        let f = c.byte()
        let g = c.byte()
        let typed = text(c.until(0x0A))
        var context = NameTemplate.Context()
        context.cursorName = name255(c.until(0x0A))
        context.cursorIsFolder = f & 1 != 0
        context.cursorSize = f & 2 != 0 ? Int64.max : Int64(g)
        context.parentName = name255(c.until(0x0A))
        context.grandparentName = name255(c.until(0x0A))
        context.now = Date(timeIntervalSince1970: 1_700_000_000.5)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        calendar.locale = enUS
        context.calendar = calendar
        context.clipboard = f & 4 != 0 ? nil : text(c.until(0x0A)).replacingOccurrences(of: "\u{1}", with: "\n")
        context.environment = ["HOME": "/Users/me", "X": "a:b/c\\d", "E": ""]
        let salt = UInt64(g)
        if f & 8 != 0 {
            context.exists = { name in
                (name.utf8.reduce(salt &+ 0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }) >> 40 % 4
                    != 0
            }
        }
        let t = Date()
        let names = try? NameTemplate.names(from: typed, context: context, quotedLists: f & 16 != 0)
        _ = NameTemplate.rangePreview(typed, context: context)
        let dt = Date().timeIntervalSince(t)
        if dt > slowestTemplate, dt > 0.005 {
            slowestTemplate = dt
            fzNote("nametemplate slowest \(Int(dt * 1_000)) ms typed=\(typed.debugDescription.prefix(300))")
        }
        // A list part that expands to nothing ("<[T2+1D]", "<a|[U]") comes back as an empty name, while a
        // counter range filters such names out: noted in the results, not failed, so the run goes on.
        if let names {
            for name in names { fzCheck(!name.isEmpty, "nametemplate-empty-name", typed.debugDescription) }
        }
    })

fuzzMain([myers, textDiff, inline, loader, renameMask, renameRegex, planner, nameTemplate])
