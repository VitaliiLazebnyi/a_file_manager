import FuzzCore

@testable import ViewerPlugin

/// The `rows` target: the text layout, built in segments, raw and decoded, against the layout built in one piece.
internal enum RowsTarget {
    /// The target.
    @MainActor
    internal static func make() -> FuzzTarget {
        FuzzTarget(
            "rows",
            maxLen: 6_000,
            dict: [
                "\r\n", "\n", "\r", "\t", " ", "\r\r\n", "\n\n\n\n", "a b c d e f g ", "\u{3000}", "\u{2028}", "\u{85}",
                "é", "日本", "😀", "e\u{301}"
            ],
            rawDict: [
                [0x0D, 0x00, 0x0A, 0x00], [0x00, 0x0D, 0x00, 0x0A], [0x0A, 0x00], [0x00, 0x0A], [0x09, 0x00],
                [0x3D, 0xD8, 0x00, 0xDE], [0x81, 0x0A], [0x81, 0x40], [0x82, 0xA0], [0xE2, 0x80], [0xFF], [0xC3]
            ],
            seeds: seeds,
            run: run
        )
    }

    /// The inputs the fuzzer starts from: the choices of `RowsInput`, then the text.
    internal static func seeds() -> [[UInt8]] {
        func seed(_ head: [UInt8], _ text: String) -> [UInt8] {
            head + Array(text.utf8)
        }
        let prose =
            "The quick brown fox jumps over the lazy dog.\r\nSecond line\twith tabs\tand a very long tail "
            + String(repeating: "word ", count: 60) + "\n\n\rend"
        let utf16 = Array("ab cd\r\nef".utf16).flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] }
        return [
            seed([0, 20, 1, 8, 50, 20, 0, 0, 3], prose), seed([0, 80, 0, 4, 7, 3, 1, 0, 9], prose),
            seed([3, 5, 1, 1, 255, 255, 1, 0, 1], prose),
            seed([7, 10, 1, 8, 16, 5, 0, 0, 2], "日本語のテキスト\n改行 あり\r\n"),
            [1, 7, 1, 8, 10, 4, 0, 2, 5, 0xFF, 0xFE] + utf16,
            [8, 3, 0, 2, 9, 3, 1, 0, 4, 0x82, 0xA0, 0x82, 0xA2, 0x0A, 0x81, 0x82, 0xA0, 0x20, 0x82, 0xA0]
        ]
    }

    /// Runs one input.
    @MainActor
    internal static func run(_ bytes: [UInt8]) {
        let input = RowsInput(bytes)
        let (document, rows) = build(
            input,
            segment: input.segment,
            chunk: input.chunk,
            raw: true,
            parallel: input.parallel
        )
        let (_, decoded) = build(input, segment: input.segment, chunk: input.chunk, raw: false, parallel: false)
        let (whole, reference) = build(input, segment: 1 << 22, chunk: 1 << 20, raw: false, parallel: false)
        compare(rows, decoded, "rows-raw-differs-from-decoded", input)
        compare(decoded, reference, "rows-segmented-differs-from-whole", input)
        fzCheck(document.rowCount == rows.count, "rows-count", input.what)
        fzCheck(
            document.lineCount == whole.lineCount,
            "rows-line-count",
            "\(input.what): \(document.lineCount) against \(whole.lineCount)"
        )
        let lines = checkCover(document, rows, input)
        // Lookups by offset and by row agree.
        var probe = Choices(bytes.reversed())
        for _ in 0..<min(24, input.probes) {
            checkLookup(document, rows, lines: lines, input, probe: &probe)
        }
        _ = try? document.row(containing: -5)
        _ = try? document.row(containing: Int64.max)
        _ = try? document.row(ofLine: 0)
        _ = try? document.row(ofLine: Int.max)
        _ = try? document.rows(from: rows.count, count: 3)
        _ = try? document.rows(from: max(0, rows.count - 1), count: Int.max)
        checkReuse(document, input)
        checkByteLayouts(input, probe: &probe)
        if input.data.count > 2 {
            _ = try? document.text(in: 1..<Int64(input.data.count - 1))
        }
    }

    /// Every row of `document`, read 97 at a time.
    @MainActor
    internal static func allRows(_ document: TextDocument, _ what: String) -> [RowKey] {
        var out: [RowKey] = []
        let count = document.rowCount
        var first = 0
        while first < count {
            let rows = (try? document.rows(from: first, count: 97)) ?? []
            fzCheck(!rows.isEmpty, "rows-missing", "\(what): no rows from \(first) of \(count)")
            for (index, row) in rows.enumerated() {
                fzCheck(row.index == first + index, "rows-index", "\(what): \(row.index) at \(first + index)")
                out.append(RowKey(row))
            }
            first += rows.count
        }
        return out
    }

    /// A text document of the input with its index built so, and its rows.
    @MainActor
    private static func build(
        _ input: RowsInput,
        segment: Int,
        chunk: Int,
        raw: Bool,
        parallel: Bool
    ) -> (TextDocument, [RowKey]) {
        let document = TextDocument(
            source: input.source,
            encoding: input.encoding,
            bomLength: input.bom,
            layout: .text(input.options)
        )
        document.buildIndex(parallel: parallel, segmentSize: segment, chunkSize: chunk, rawScan: raw)
        fzCheck(document.isIndexComplete, "rows-index-incomplete", input.what)
        fzCheck(document.readError == nil, "rows-read-error", input.what)
        return (document, allRows(document, input.what))
    }

    /// Fails with `key` where the rows differ.
    @MainActor
    internal static func compare(_ left: [RowKey], _ right: [RowKey], _ key: String, _ input: RowsInput) {
        if left.count != right.count {
            fzFail(key, "\(input.what): \(left.count) rows against \(right.count)\n\(describe(input.data))")
        }
        for index in left.indices where left[index] != right[index] {
            fzFail(key, "\(input.what): row \(index): \(left[index]) against \(right[index])\n\(describe(input.data))")
        }
    }

    /// The rows cover the content exactly once, in order; returns the lines counted.
    @MainActor
    private static func checkCover(_ document: TextDocument, _ rows: [RowKey], _ input: RowsInput) -> Int {
        let what = input.what
        let content = document.content
        var start = content.lowerBound
        var line = 0
        for (index, row) in rows.enumerated() {
            fzCheck(
                row.range.lowerBound == start,
                "rows-gap-or-overlap",
                "\(what): row \(index) starts at \(row.range.lowerBound), expected \(start)\n\(describe(input.data))"
            )
            fzCheck(
                row.range.upperBound > start,
                "rows-empty-row",
                "\(what): row \(index) \(row.range)\n\(describe(input.data))"
            )
            if row.startsLine {
                line += 1
            }
            checkRow(row, index: index, line: line, input)
            start = row.range.upperBound
        }
        fzCheck(
            start == content.upperBound,
            "rows-do-not-reach-end",
            "\(what): rows end at \(start), content at \(content.upperBound)\n\(describe(input.data))"
        )
        if !rows.isEmpty {
            fzCheck(
                document.lineCount == line,
                "rows-line-count-vs-rows",
                "\(what): \(document.lineCount) against \(line)"
            )
        }
        return line
    }

    /// One row on its own: the content end, the line number, the offsets.
    @MainActor
    private static func checkRow(_ row: RowKey, index: Int, line: Int, _ input: RowsInput) {
        let what = input.what
        fzCheck(
            row.contentEnd >= row.range.lowerBound && row.contentEnd <= row.range.upperBound,
            "rows-content-end",
            "\(what): row \(index)"
        )
        fzCheck(
            row.line == line,
            "rows-line-number",
            "\(what): row \(index) says line \(row.line), counted \(line)\n\(describe(input.data))"
        )
        fzCheck(
            row.offsets.count == row.text.utf16.count,
            "rows-offsets-count",
            "\(what): row \(index): \(row.offsets.count) offsets for \(row.text.utf16.count) units"
        )
        var last: Int32 = 0
        for offset in row.offsets {
            fzCheck(
                offset >= last && Int64(offset) <= row.range.upperBound - row.range.lowerBound,
                "rows-offsets-order",
                "\(what): row \(index)"
            )
            last = offset
        }
    }
}
