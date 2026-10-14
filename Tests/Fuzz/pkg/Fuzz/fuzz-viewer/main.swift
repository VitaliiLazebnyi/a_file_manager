import Foundation
import FuzzCore
import AFMKernel
@testable import ViewerPlugin

// Target group 6: the viewer's model. Every random choice comes out of the input bytes.

let encodings: [ViewerEncoding] = [.utf8, .utf16LE, .utf16BE, .ansi, .dos, .latin1, .macRoman] + [932, 936, 949, 950, 1251, 874].compactMap(ViewerEncoding.codePage)
let doubleByte = encodings.filter { $0.kind == .doubleByte }

func describe(_ bytes: [UInt8]) -> String { bytes.prefix(200).map { String(format: "%02x", $0) }.joined(separator: " ") }

/// A size from the input: mostly small (so borders fall everywhere), sometimes larger.
func size(_ c: inout Choices, least: Int = 1) -> Int {
    let v = Int(c.byte())
    let s = v < 200 ? v : (v - 199) * 37
    return max(least, s)
}

// MARK: - encoding detection and decoding

let detect = FuzzTarget("detect", maxLen: 8192,
    dict: ["charset=", "windows-1252", "windows-99999999999999999999", "utf-16be", "<html", "<!doctype html", "%PDF-", "{\\rtf", "RIFF", "WEBP", ".html", ".bmp"],
    rawDict: [[0xEF, 0xBB, 0xBF], [0xFF, 0xFE], [0xFE, 0xFF], [0xD8, 0x00], [0x00, 0xD8], [0xDC, 0x00], [0x81, 0x40], [0xF0, 0x9F, 0x98, 0x80], [0xED, 0xA0, 0x80], [0xC0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xE2, 0x82]],
    seeds: { [Array("\u{1}\u{3}\u{2}hello wörld €\n日本語 text\r\n".utf8), [3, 5, 9, 0xFF, 0xFE, 0x41, 0, 0x3D, 0xD8, 0, 0xDE, 0x0A, 0],
              [8, 2, 2, 0x82, 0xA0, 0x82, 0xA2, 0x41, 0x81, 0x0A, 0x95, 0x5C], Array("\u{0}\u{1}\u{1}<html><meta charset=\"windows-1251\">".utf8)] },
    run: { bytes in
        var c = Choices(bytes)
        let encoding = encodings[c.int(encodings.count)]
        let cutA = size(&c), cutB = size(&c)
        let data = c.rest()
        let d = Data(data)
        // Detection never traps and is stable.
        let g1 = ViewerDetection.guessText(d, isWholeFile: true)
        _ = ViewerDetection.guessText(d, isWholeFile: false)
        fzCheck(g1 == ViewerDetection.guessText(d, isWholeFile: true), "detect-unstable")
        fzCheck(g1.bomLength >= 0 && g1.bomLength <= data.count, "detect-bom-length", "\(g1.bomLength) of \(data.count)")
        _ = ViewerDetection.content(name: String(decoding: data.prefix(40), as: UTF8.self), sample: d)
        _ = ViewerDetection.content(name: "a.txt", sample: d)
        _ = ViewerDetection.htmlCharset(d)
        _ = ViewerDetection.extensions(in: String(decoding: data.prefix(100), as: UTF8.self))
        _ = HexFormat.hexString(d.prefix(64))
        for e in [encoding, g1.encoding] {
            // The whole in one go.
            var whole = DecodedText()
            let used = e.decode(data, final: true, into: &whole)
            fzCheck(used == data.count, "decode-final-leaves-bytes", "\(e.codePage): used \(used) of \(data.count): \(describe(data))")
            fzCheck(whole.offsets.count == whole.units.count, "decode-offset-count", "\(e.codePage)")
            var last: Int32 = 0
            for o in whole.offsets {
                fzCheck(o >= last && Int(o) < max(1, data.count), "decode-offsets-order", "\(e.codePage): \(describe(data))")
                last = o
            }
            fzCheck(e.units(from: d) == whole.units, "decode-units-differ", "\(e.codePage)")
            _ = e.string(from: d)
            // Piece by piece: what a piece leaves is handed in again with the next.
            var units: [UInt16] = [], offsets: [Int] = []
            var at = 0, turn = 0
            var piece = DecodedText()
            while at < data.count {
                let step = max(1, turn % 2 == 0 ? cutA : cutB)
                turn += 1
                var end = min(data.count, at + step)
                var took = 0
                while true {
                    let final = end == data.count
                    took = e.decode(Array(data[at..<end]), final: final, into: &piece)
                    fzCheck(took >= 0 && took <= end - at, "decode-used-out-of-range", "\(e.codePage): \(took) of \(end - at)")
                    if took > 0 || final { break }
                    end = min(data.count, end + 1)   // a piece too small to hold one character grows
                }
                units += piece.units
                offsets += piece.offsets.map { Int($0) + at }
                at += took
                if took == 0 { break }
            }
            fzCheck(units == whole.units, "decode-pieces-differ-text", "\(e.codePage) cuts \(cutA)/\(cutB): \(describe(data))")
            fzCheck(offsets == whole.offsets.map { Int($0) }, "decode-pieces-differ-offsets", "\(e.codePage) cuts \(cutA)/\(cutB): \(describe(data))")
            if let back = e.encode(String(decoding: whole.units.prefix(64), as: UTF16.self)) { _ = back.count }
        }
    })

// MARK: - rows

struct RowKey: Equatable { let range: Range<Int64>; let contentEnd: Int64; let text: String; let offsets: [Int32]; let startsLine: Bool; let line: Int }

func allRows(_ document: TextDocument, _ what: String) -> [RowKey] {
    var out: [RowKey] = []
    let count = document.rowCount
    var first = 0
    while first < count {
        let rows = (try? document.rows(from: first, count: 97)) ?? []
        fzCheck(!rows.isEmpty, "rows-missing", "\(what): no rows from \(first) of \(count)")
        for (i, r) in rows.enumerated() {
            fzCheck(r.index == first + i, "rows-index", "\(what): \(r.index) at \(first + i)")
            out.append(RowKey(range: r.range, contentEnd: r.contentEnd, text: r.text, offsets: r.offsets, startsLine: r.startsLine, line: r.line))
        }
        first += rows.count
    }
    return out
}

let rowsTarget = FuzzTarget("rows", maxLen: 6000,
    dict: ["\r\n", "\n", "\r", "\t", " ", "\r\r\n", "\n\n\n\n", "a b c d e f g ", "\u{3000}", "\u{2028}", "\u{85}", "é", "日本", "😀", "e\u{301}"],
    rawDict: [[0x0D, 0x00, 0x0A, 0x00], [0x00, 0x0D, 0x00, 0x0A], [0x0A, 0x00], [0x00, 0x0A], [0x09, 0x00], [0x3D, 0xD8, 0x00, 0xDE], [0x81, 0x0A], [0x81, 0x40], [0x82, 0xA0], [0xE2, 0x80], [0xFF], [0xC3]],
    seeds: {
        func seed(_ head: [UInt8], _ text: String) -> [UInt8] { head + Array(text.utf8) }
        let prose = "The quick brown fox jumps over the lazy dog.\r\nSecond line\twith tabs\tand a very long tail " + String(repeating: "word ", count: 60) + "\n\n\rend"
        return [seed([0, 20, 1, 8, 50, 20, 0, 0, 3], prose), seed([0, 80, 0, 4, 7, 3, 1, 0, 9], prose), seed([3, 5, 1, 1, 255, 255, 1, 0, 1], prose),
                seed([7, 10, 1, 8, 16, 5, 0, 0, 2], "日本語のテキスト\n改行 あり\r\n"), [1, 7, 1, 8, 10, 4, 0, 2, 5, 0xFF, 0xFE] + Array("ab cd\r\nef".utf16).flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] },
                [8, 3, 0, 2, 9, 3, 1, 0, 4, 0x82, 0xA0, 0x82, 0xA2, 0x0A, 0x81, 0x82, 0xA0, 0x20, 0x82, 0xA0]]
    },
    run: { bytes in
        var c = Choices(bytes)
        let encoding = encodings[c.int(encodings.count)]
        let columns = 1 + Int(c.u16()) % 500
        let wrap = c.bool()
        let tab = Int(c.byte()) % 20            // 0 is made 1 by the options
        let segment = size(&c), chunk = size(&c)
        let parallel = c.bool()
        let bom = c.int(4)
        let probes = Int(c.byte())
        let data = c.rest()
        let source = DataByteSource(Data(data))
        let options = TextLayoutOptions(columns: columns, wordWrap: wrap, tabWidth: tab)
        let what = "cp \(encoding.codePage) columns \(columns) wrap \(wrap) tab \(tab) segment \(segment) chunk \(chunk) bom \(bom) bytes \(data.count)"

        func build(_ segment: Int, _ chunk: Int, raw: Bool, parallel: Bool) -> (TextDocument, [RowKey]) {
            let document = TextDocument(source: source, encoding: encoding, bomLength: bom, layout: .text(options))
            document.buildIndex(parallel: parallel, segmentSize: segment, chunkSize: chunk, rawScan: raw)
            fzCheck(document.isIndexComplete, "rows-index-incomplete", what)
            fzCheck(document.readError == nil, "rows-read-error", what)
            return (document, allRows(document, what))
        }
        let (document, rows) = build(segment, chunk, raw: true, parallel: parallel)
        let (_, decoded) = build(segment, chunk, raw: false, parallel: false)
        let (whole, reference) = build(1 << 22, 1 << 20, raw: false, parallel: false)

        func compare(_ a: [RowKey], _ b: [RowKey], _ key: String) {
            if a.count != b.count { fzFail(key, "\(what): \(a.count) rows against \(b.count)\n\(describe(data))") }
            for i in a.indices where a[i] != b[i] { fzFail(key, "\(what): row \(i): \(a[i]) against \(b[i])\n\(describe(data))") }
        }
        compare(rows, decoded, "rows-raw-differs-from-decoded")
        compare(decoded, reference, "rows-segmented-differs-from-whole")
        fzCheck(document.rowCount == rows.count, "rows-count", what)
        fzCheck(document.lineCount == whole.lineCount, "rows-line-count", "\(what): \(document.lineCount) against \(whole.lineCount)")

        // The rows cover the content exactly once, in order.
        let content = document.content
        var at = content.lowerBound
        var line = 0
        for (i, r) in rows.enumerated() {
            fzCheck(r.range.lowerBound == at, "rows-gap-or-overlap", "\(what): row \(i) starts at \(r.range.lowerBound), expected \(at)\n\(describe(data))")
            fzCheck(r.range.upperBound > at, "rows-empty-row", "\(what): row \(i) \(r.range)\n\(describe(data))")
            fzCheck(r.contentEnd >= r.range.lowerBound && r.contentEnd <= r.range.upperBound, "rows-content-end", "\(what): row \(i)")
            if r.startsLine { line += 1 }
            fzCheck(r.line == line, "rows-line-number", "\(what): row \(i) says line \(r.line), counted \(line)\n\(describe(data))")
            fzCheck(r.offsets.count == r.text.utf16.count, "rows-offsets-count", "\(what): row \(i): \(r.offsets.count) offsets for \(r.text.utf16.count) units")
            var last: Int32 = 0
            for o in r.offsets {
                fzCheck(o >= last && Int64(o) <= r.range.upperBound - r.range.lowerBound, "rows-offsets-order", "\(what): row \(i)")
                last = o
            }
            at = r.range.upperBound
        }
        fzCheck(at == content.upperBound, "rows-do-not-reach-end", "\(what): rows end at \(at), content at \(content.upperBound)\n\(describe(data))")
        if !rows.isEmpty { fzCheck(document.lineCount == line, "rows-line-count-vs-rows", "\(what): \(document.lineCount) against \(line)") }

        // Lookups by offset and by row agree.
        var probe = Choices(bytes.reversed())
        for _ in 0..<min(24, probes) {
            let offset = content.isEmpty ? content.lowerBound : content.lowerBound + Int64(Int(probe.u16()) % (data.count - Int(content.lowerBound) + 1))
            let found = try? document.row(containing: offset)
            if rows.isEmpty { fzCheck(found == .some(0), "rows-lookup-empty", "\(what): \(String(describing: found))"); continue }
            guard let row = found else { fzFail("rows-lookup-nil", "\(what): offset \(offset)") }
            fzCheck(row >= 0 && row < rows.count, "rows-lookup-out-of-range", "\(what): offset \(offset) row \(row)")
            let r = rows[row]
            let inside = r.range.contains(offset) || (offset == content.upperBound && row == rows.count - 1)
            fzCheck(inside, "rows-lookup-wrong-row", "\(what): offset \(offset) gives row \(row) \(r.range)\n\(describe(data))")
            let wantLine = 1 + (Int(probe.byte()) % max(1, line))
            let first = rows.firstIndex { $0.startsLine && $0.line == wantLine }
            let got = try? document.row(ofLine: wantLine)
            fzCheck(got == first, "rows-line-lookup", "\(what): line \(wantLine) gives \(String(describing: got)), expected \(String(describing: first))\n\(describe(data))")
            // Geometry on the row.
            if let shown = (try? document.rows(from: row, count: 1))?.first {
                let index = document.textIndex(in: shown, of: offset)
                fzCheck(index >= 0 && index <= shown.offsets.count, "rows-text-index", what)
                let back = document.byteOffset(in: shown, at: index)
                fzCheck(back >= shown.range.lowerBound && back <= shown.range.upperBound, "rows-byte-offset", what)
                _ = document.textRanges(in: shown, for: min(offset, back)..<max(offset, back) + 1)
                _ = document.byteOffset(in: shown, at: Int(probe.byte()))
            }
        }
        _ = try? document.row(containing: -5)
        _ = try? document.row(containing: Int64.max)
        _ = try? document.row(ofLine: 0)
        _ = try? document.row(ofLine: Int.max)
        _ = try? document.rows(from: rows.count, count: 3)
        _ = try? document.rows(from: max(0, rows.count - 1), count: Int.max)

        // The layout before is taken over where it fits (another width).
        let again = TextDocument(source: source, encoding: encoding, bomLength: bom, layout: .text(TextLayoutOptions(columns: 1 + (columns * 7) % 500, wordWrap: wrap, tabWidth: tab)), reusing: document)
        again.buildIndex(parallel: parallel, segmentSize: segment, chunkSize: chunk)
        let fresh = TextDocument(source: source, encoding: encoding, bomLength: bom, layout: .text(TextLayoutOptions(columns: 1 + (columns * 7) % 500, wordWrap: wrap, tabWidth: tab)))
        fresh.buildIndex(parallel: false, segmentSize: 1 << 22, chunkSize: 1 << 20, rawScan: false)
        compare(allRows(again, what), allRows(fresh, what), "rows-reused-index-differs")

        // The byte layouts.
        let widths = [Int(probe.byte()), 0, -1, 16]
        for layout in [ViewerLayout.hex, .binary(width: widths[0]), .binary(width: widths[1 + probe.int(3)])] {
            let fixed = TextDocument(source: source, encoding: encoding, layout: layout)
            fixed.buildIndex(parallel: parallel)
            let count = fixed.rowCount
            var covered: Int64 = 0
            var first = 0
            while first < count {
                let part = (try? fixed.rows(from: first, count: 500)) ?? []
                fzCheck(!part.isEmpty, "fixed-rows-missing", "\(layout) \(first) of \(count)")
                for r in part {
                    fzCheck(r.range.lowerBound == covered, "fixed-rows-gap", "\(layout)")
                    covered = r.range.upperBound
                    _ = fixed.byteOffset(in: r, at: Int(probe.byte()))
                    _ = fixed.textIndex(in: r, of: Int64(probe.u16()))
                    _ = fixed.textRanges(in: r, for: Int64(probe.byte())..<Int64(probe.byte()) + 300)
                }
                first += part.count
            }
            fzCheck(covered == Int64(data.count), "fixed-rows-do-not-reach-end", "\(layout): \(covered) of \(data.count)")
            _ = try? fixed.row(containing: Int64(probe.u16()))
            _ = try? fixed.row(ofLine: Int(probe.byte()))
        }
        if data.count > 2 { _ = try? document.text(in: 1..<Int64(data.count - 1)) }
    })

// MARK: - character boundaries

let boundariesTarget = FuzzTarget("boundaries", maxLen: 4096,
    rawDict: [[0x81, 0x40], [0x82, 0xA0], [0x81], [0xFE, 0xFE], [0x0A], [0x20], [0x81, 0x3F], [0xE0, 0x40], [0x80], [0xFF], [0xA1, 0xA1], [0x81, 0x81, 0x81, 0x81, 0x81, 0x81, 0x81]],
    seeds: { [[0, 0, 0, 30] + [UInt8](repeating: 0x82, count: 70) + [0xA0, 0x0A, 0x41] + [UInt8](repeating: 0x81, count: 41),
              [1, 3, 2, 20] + (0..<120).map { UInt8(0x81 + ($0 * 7) % 0x7E) }, [2, 9, 1, 10, 0x41, 0x81], [3, 1, 0, 9, 0x81, 0x40, 0x81, 0x30, 0x81]] },
    run: { bytes in
        var c = Choices(bytes)
        guard !doubleByte.isEmpty else { return }
        let encoding = doubleByte[c.int(doubleByte.count)]
        let spacing = 16 + Int(c.byte())
        let lower = Int(c.byte()) % 8
        let probes = Int(c.byte())
        let data = c.rest()
        let content = Int64(min(lower, data.count))..<Int64(data.count)
        let source = DataByteSource(Data(data))
        // From the start: the characters as the decoder counts them.
        var text = DecodedText()
        encoding.decode(Array(data[Int(content.lowerBound)...]), final: true, into: &text)
        var isStart = [Bool](repeating: false, count: data.count + 1)
        for o in text.offsets { isStart[Int(content.lowerBound) + Int(o)] = true }
        var expected = [Int64](repeating: content.lowerBound, count: data.count + 1)
        var last = content.lowerBound
        for i in Int(content.lowerBound)..<data.count { if isStart[i] { last = Int64(i) }; expected[i] = last }
        let boundaries = CharacterBoundaries(source: source, content: content, encoding: encoding, spacing: spacing)
        var probe = Choices(bytes.reversed())
        let what = "cp \(encoding.codePage) spacing \(spacing) content \(content)"
        for turn in 0..<min(40, probes + 1) where !content.isEmpty {
            // First far in, where the block's boundary has to be found without the ones before.
            let offset = turn == 0 ? content.upperBound - 1 : content.lowerBound + Int64(Int(probe.u16()) % Int(content.count))
            guard let got = try? boundaries.characterStart(atOrBefore: offset) else { fzFail("boundaries-threw", what) }
            fzCheck(got == expected[Int(offset)], "boundaries-differ-from-decoder", "\(what): offset \(offset) gives \(got), decoding from the start gives \(expected[Int(offset)])\n\(describe(data))")
        }
        _ = try? boundaries.characterStart(atOrBefore: -3)
        _ = try? boundaries.characterStart(atOrBefore: Int64.max)
        _ = boundaries.blockCount
    })

// MARK: - search

let safeExpressions = ["a+", "\\bfoo", "^x", "o$", "[0-9]+", "(?i)bar", "\\w+\\s", ".", "\\r\\n", "(a|b)c", "\\x{3042}", "x{2,3}", "\\Bb", "é", "[^\\x00-\\x7F]"]

let searchTarget = FuzzTarget("search", maxLen: 4096,
    dict: ["foo", "bar", "\\n", "\\t", "\\\\", "\"PK\"0102", "0D 0A", "ß", "ſ", "İ", "ı", "K", "é", "É", "e\u{301}", "ǅ", "σς", "\n", "\r\n", " ", "日本", "あ"],
    rawDict: [[0], [0x82, 0xA0], [0x81, 0x40], [0xE2, 0x84, 0xAA], [0xC5, 0xBF], [0xFF], [0xC3]],
    seeds: {
        func seed(_ head: [UInt8], _ pattern: String, _ text: String) -> [UInt8] { head + Array(pattern.utf8) + [0] + Array(text.utf8) }
        return [seed([0, 0, 7, 0, 2, 0], "bar", "foo bar FOO BAR foobar\nbar"), seed([0, 1, 5, 30, 1, 0], "Bar", "foo bar FOO BAR foobar\nbar Bar"),
                seed([0, 16, 9, 0, 3, 0], "b", "foo bar FOO BAR foobar\nbar"), seed([0, 8, 4, 0, 1, 0], "\"PK\"0102", "xxPK\u{1}\u{2}yy"),
                seed([3, 2, 6, 0, 2, 0], "über", "Über die Brücke über"), seed([7, 0, 3, 0, 2, 0], "界", "你好世界你好"),
                seed([0, 0, 11, 0, 2, 0], "a\\nb", "xa\r\nb a\nb"), seed([0, 4, 8, 99, 2, 0], "ss", "Straße STRASSE ſs KELVIN K")]
    },
    run: { bytes in
        var c = Choices(bytes)
        let encoding = encodings[c.int(encodings.count)]
        let flags = c.byte()
        var options = SearchOptions()
        options.caseSensitive = flags & 1 != 0
        options.wholeWords = flags & 2 != 0
        options.backwards = flags & 4 != 0
        options.hex = flags & 8 != 0
        options.regex = flags & 16 != 0
        let chunk = size(&c)
        let startChoice = Int(c.u16())
        let parallelism = 1 + c.int(4)
        let patternBytes = c.until(0)
        let data = c.rest()
        var typed = String(decoding: patternBytes.prefix(48), as: UTF8.self)
        // Expressions are the user's own; only harmless ones are tried, so that time spent is the search's.
        if options.regex && !options.hex { typed = safeExpressions[patternBytes.reduce(0) { ($0 &+ Int($1)) } % safeExpressions.count] }
        guard let pattern = try? SearchPattern(typed, options: options, encoding: encoding) else { return }
        let source = DataByteSource(Data(data))
        let bom = Int64(min(data.count, Int(flags >> 6)))
        let content = bom..<Int64(data.count)
        let start = Int64(startChoice % (data.count + 2)) - 1 + (flags & 32 != 0 ? 0 : 0)
        let what = "cp \(encoding.codePage) pattern \(typed.debugDescription) \(options) chunk \(chunk) start \(start) content \(content) parallelism \(parallelism)"
        func find(_ chunk: Int, raw: Bool, shared: CharacterBoundaries? = nil, from: Int64) -> Range<Int64>?? {
            do {
                return .some(try ViewerSearch.find(pattern, in: source, content: content, from: from, backwards: options.backwards, encoding: encoding,
                                                   chunkSize: chunk, parallelism: parallelism, boundaries: shared, rawBytes: raw))
            } catch { return nil }
        }
        let shared = encoding.kind == .doubleByte ? CharacterBoundaries(source: source, content: content, encoding: encoding, spacing: 16 + chunk % 64) : nil
        guard let raw = find(chunk, raw: true, shared: shared, from: start), let decoded = find(chunk, raw: false, from: start) else { fzFail("search-threw", what) }
        if raw != decoded { fzFail("search-raw-differs-from-decoded", "\(what): raw \(String(describing: raw)), decoded \(String(describing: decoded))\n\(describe(data))") }
        if let m = raw {
            fzCheck(m.lowerBound >= content.lowerBound && m.upperBound <= content.upperBound && m.lowerBound <= m.upperBound, "search-match-outside-content", "\(what): \(m)")
            let from = min(max(start, content.lowerBound), content.upperBound)
            // A backwards search never returns the match that begins at `start` (Find Previous would repeat it),
            // also when the match is shorter in the text than the needle (ß for "ss"). The tolerance the first
            // campaign needed for that finding is gone.
            fzCheck(options.backwards ? m.lowerBound < from : m.lowerBound >= from, "search-match-wrong-side", "\(what): \(m)\n\(describe(data))")
        }
        // Plain text and bytes: the chunk size changes nothing.
        switch pattern.kind {
        case .expression: break
        case .text, .bytes:
            guard let whole = find(1 << 20, raw: false, from: start) else { fzFail("search-threw", what) }
            if whole != decoded { fzFail("search-chunked-differs-from-whole", "\(what): chunked \(String(describing: decoded)), in one piece \(String(describing: whole))\n\(describe(data))") }
        }
        // Find next from the match, as F3 does.
        if let m = raw, m.upperBound > m.lowerBound {
            let next = options.backwards ? m.lowerBound : m.lowerBound + 1
            guard let a = find(chunk, raw: true, shared: shared, from: next), let b = find(chunk, raw: false, from: next) else { fzFail("search-threw", what) }
            if a != b { fzFail("search-raw-differs-from-decoded", "\(what) (next from \(next)): raw \(String(describing: a)), decoded \(String(describing: b))\n\(describe(data))") }
        }
    })

// MARK: - HTML

var htmlNotes = 0.0
let htmlTarget = FuzzTarget("html", maxLen: 1 << 15,
    dict: ["<", ">", "</", "<a href=\"", "<a href='", "<a href=", "</a>", "<script>", "</script>", "<style>", "</style", "<pre>", "</pre>", "<br>", "<p>", "<li>", "<!--", "-->", "&amp;", "&#", "&#x", ";", "&#1114112;", "&#xFFFFFFFFFF;",
           "&#99999999999999999999;", "&#xD800;", "&#0;", "&nbsp;", "&", "<svg", "<template>", "<noscript>", "<title>", "\"", "'", "=", " ", "\n", "<![CDATA[", "]]>", "<?", "<a", "href", "<a href=\"&#x41;&amp;\">", "<<<<<<<<", "&&&&&&&&", "<a <a <a ", "<script<script"],
    rawDict: [[0xED, 0xA0, 0x80], [0xF0, 0x9F, 0x98, 0x80], [0xC2, 0xA0], [0xE2, 0x80, 0xA8]],
    seeds: { ["\u{0}<html><head><title>T</title><style>p{}</style><script>var a='</p>';</script></head><body><h1>Head</h1><p>Some <b>bold</b> &amp; <a href=\"http://x.example/a?b=1&amp;c=2\">link</a> text&nbsp;here.</p><pre>  keep\n   this </pre><ul><li>one<li>two</ul><!-- note --><br/>&#65;&#x42;&bogus; &lt;tag&gt;</body></html>",
              "\u{1}<a href='x'>y</a><a href=z>w</a><a>none</a><svg><a href=q>in</a></svg>tail &#x1F600; &#128512;",
              "\u{2}<p>unterminated <a href=\"foo", "\u{3}plain & simple < text > here"].map { Array($0.utf8) } },
    run: { bytes in
        var c = Choices(bytes)
        let mode = c.byte()
        let braces = mode & 1 == 0
        let body = c.rest()
        var units: [UInt16]
        if mode & 2 == 0 { units = Array(String(decoding: body, as: UTF8.self).utf16) }
        else {
            // Units as they come from a UTF-16 file: lone surrogates and all.
            units = []
            var i = 0
            while i + 1 < body.count { units.append(UInt16(body[i]) | UInt16(body[i + 1]) << 8); i += 2 }
            if mode & 4 != 0 { units = units.map { $0 & 0x00FF == $0 ? $0 : ($0 & 0x7F) } }
        }
        let t = Date()
        let fast = HTMLText.plainText(units: units, linkBraces: braces)
        let dt = Date().timeIntervalSince(t)
        if units.count >= 512 {
            let perKB = dt / (Double(units.count) / 1024)
            if perKB > htmlNotes { htmlNotes = perKB; fzNote("html slowest \(Int(perKB * 1e6)) us per 1024 units, \(units.count) units, starts \(String(decoding: units.prefix(60), as: UTF16.self).debugDescription)") }
        }
        let reference = HTMLReference.plainText(units: units, linkBraces: braces)
        if fast != reference {
            fzFail("html-differs-from-reference", "braces \(braces): \(String(decoding: units, as: UTF16.self).debugDescription.prefix(600))\nfast: \(String(describing: fast).prefix(700))\nreference: \(String(describing: reference).prefix(700))")
        }
        if let fast { fzCheck(fast.text.utf16.count <= units.count * 8 + 64, "html-output-much-larger", "\(units.count) units give \(fast.text.utf16.count)") }
        let text = String(decoding: units.prefix(300), as: UTF16.self)
        _ = HTMLText.plainText(from: text, linkBraces: braces)
        _ = HTMLText.attribute("href", in: text[...])
        _ = HTMLText.decodeEntities(text[...])
        _ = HTMLText.decodeEntity(String(text.prefix(12)))
        _ = HTMLText.url(from: text)
    })

/// `fuzz-viewer scale FILE`: the time of plainText for the input repeated 1, 2, 4, 8, 16 times.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "scale" {
    let body = [UInt8](FileManager.default.contents(atPath: CommandLine.arguments[2]) ?? Data())
    let unit = Array(String(decoding: body, as: UTF8.self).utf16)
    for factor in [1, 2, 4, 8, 16, 32] {
        var units: [UInt16] = []
        for _ in 0..<factor { units += unit }
        var best = Double.infinity
        for _ in 0..<3 { let t = Date(); _ = HTMLText.plainText(units: units); best = min(best, Date().timeIntervalSince(t)) }
        print("x\(factor): \(units.count) units, \(String(format: "%.3f", best * 1000)) ms, \(String(format: "%.2f", best * 1e6 / (Double(units.count) / 1024))) us per 1024 units")
    }
    exit(0)
}

fuzzMain([detect, rowsTarget, boundariesTarget, searchTarget, htmlTarget])
