import FuzzCore

@testable import ViewerPlugin

/// The lookups, the reused index and the byte layouts of the `rows` target.
extension RowsTarget {
    /// One lookup: the row of an offset, the row of a line, and the geometry on the row.
    @MainActor
    internal static func checkLookup(
        _ document: TextDocument,
        _ rows: [RowKey],
        lines: Int,
        _ input: RowsInput,
        probe: inout Choices
    ) {
        let what = input.what
        let content = document.content
        let span = input.data.count - Int(content.lowerBound) + 1
        let offset = content.isEmpty ? content.lowerBound : content.lowerBound + Int64(Int(probe.u16()) % span)
        let found = try? document.row(containing: offset, cancellation: nil)
        if rows.isEmpty {
            fzCheck(found == .some(0), "rows-lookup-empty", "\(what): \(String(describing: found))")
            return
        }
        guard let row = found else {
            fzFail("rows-lookup-nil", "\(what): offset \(offset)")
        }
        fzCheck(row >= 0 && row < rows.count, "rows-lookup-out-of-range", "\(what): offset \(offset) row \(row)")
        let key = rows[row]
        let inside = key.range.contains(offset) || (offset == content.upperBound && row == rows.count - 1)
        fzCheck(
            inside,
            "rows-lookup-wrong-row",
            "\(what): offset \(offset) gives row \(row) \(key.range)\n\(describe(input.data))"
        )
        let wantLine = 1 + (Int(probe.byte()) % max(1, lines))
        let first = rows.firstIndex { $0.startsLine && $0.line == wantLine }
        let got = try? document.row(ofLine: wantLine, cancellation: nil)
        fzCheck(
            got == first,
            "rows-line-lookup",
            "\(what): line \(wantLine) gives \(String(describing: got)), expected \(String(describing: first))\n"
                + describe(input.data)
        )
        if let shown = (try? document.rows(from: row, count: 1, cancellation: nil))?.first {
            checkGeometry(document, shown, offset: offset, what: what, probe: &probe)
        }
    }

    /// The geometry on a row: text index and byte offset go back and forth.
    @MainActor
    private static func checkGeometry(
        _ document: TextDocument,
        _ shown: DisplayRow,
        offset: Int64,
        what: String,
        probe: inout Choices
    ) {
        let index = document.textIndex(in: shown, of: offset)
        fzCheck(index >= 0 && index <= shown.offsets.count, "rows-text-index", what)
        let back = document.byteOffset(in: shown, at: index)
        fzCheck(back >= shown.range.lowerBound && back <= shown.range.upperBound, "rows-byte-offset", what)
        _ = document.textRanges(in: shown, for: min(offset, back)..<max(offset, back) + 1)
        _ = document.byteOffset(in: shown, at: Int(probe.byte()))
    }

    /// The layout before is taken over where it fits (another width): the rows are the ones of a fresh index.
    @MainActor
    internal static func checkReuse(_ document: TextDocument, _ input: RowsInput) {
        let again = TextDocument(
            source: input.source,
            encoding: input.encoding,
            bomLength: input.bom,
            layout: .text(input.otherOptions),
            reusing: document
        )
        again.buildIndex(
            parallel: input.parallel,
            scanning: TextRowIndex.ScanOptions(segmentSize: input.segment, chunkSize: input.chunk, rawScan: true)
        ) {
            // No progress is wanted.
        }
        let fresh = TextDocument(
            source: input.source,
            encoding: input.encoding,
            bomLength: input.bom,
            layout: .text(input.otherOptions),
            reusing: nil
        )
        fresh.buildIndex(
            parallel: false,
            scanning: TextRowIndex.ScanOptions(segmentSize: 1 << 22, chunkSize: 1 << 20, rawScan: false)
        ) {
            // No progress is wanted.
        }
        compare(allRows(again, input.what), allRows(fresh, input.what), "rows-reused-index-differs", input)
    }

    /// The byte layouts: the rows cover the file from its first byte to its last.
    @MainActor
    internal static func checkByteLayouts(_ input: RowsInput, probe: inout Choices) {
        let widths = [Int(probe.byte()), 0, -1, 16]
        for layout in [ViewerLayout.hex, .binary(width: widths[0]), .binary(width: widths[1 + probe.int(3)])] {
            let fixed = TextDocument(
                source: input.source,
                encoding: input.encoding,
                bomLength: 0,
                layout: layout,
                reusing: nil
            )
            fixed.buildIndex(parallel: input.parallel, scanning: .standard) {
                // No progress is wanted.
            }
            let count = fixed.rowCount
            var covered: Int64 = 0
            var first = 0
            while first < count {
                let part = (try? fixed.rows(from: first, count: 500, cancellation: nil)) ?? []
                fzCheck(!part.isEmpty, "fixed-rows-missing", "\(layout) \(first) of \(count)")
                for row in part {
                    fzCheck(row.range.lowerBound == covered, "fixed-rows-gap", "\(layout)")
                    covered = row.range.upperBound
                    probeRow(fixed, row, probe: &probe)
                }
                first += part.count
            }
            fzCheck(
                covered == Int64(input.data.count),
                "fixed-rows-do-not-reach-end",
                "\(layout): \(covered) of \(input.data.count)"
            )
            _ = try? fixed.row(containing: Int64(probe.u16()), cancellation: nil)
            _ = try? fixed.row(ofLine: Int(probe.byte()), cancellation: nil)
        }
    }

    /// The geometry of a byte layout's row at places from the input: nothing traps.
    @MainActor
    private static func probeRow(_ document: TextDocument, _ row: DisplayRow, probe: inout Choices) {
        _ = document.byteOffset(in: row, at: Int(probe.byte()))
        _ = document.textIndex(in: row, of: Int64(probe.u16()))
        _ = document.textRanges(in: row, for: Int64(probe.byte())..<Int64(probe.byte()) + 300)
    }
}
