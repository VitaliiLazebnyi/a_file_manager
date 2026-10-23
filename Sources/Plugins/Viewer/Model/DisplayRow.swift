import Foundation

/// One row as it is drawn, with what is needed to find a place in it in the file again.
internal struct DisplayRow {
    /// The number of the row, counted from 0.
    internal let index: Int
    /// The bytes of the row, line end included.
    internal let range: Range<Int64>
    /// Where the line end begins (the end of the row when it has none).
    internal let contentEnd: Int64
    /// What is drawn: no line end, tabs expanded, control characters replaced.
    internal let text: String
    /// For each UTF-16 unit of `text`, its byte offset from the start of the row.
    ///
    /// Empty for hex rows, whose columns are fixed (`HexFormat`).
    internal let offsets: [Int32]
    /// Whether the row begins a line (and is not the continuation of a wrapped one).
    internal let startsLine: Bool
    /// The number of the line the row belongs to, counted from 1.
    internal let line: Int

    /// The row of `bytes`, which begin at `start`, in a byte layout: the hex line of `hex`, or
    /// one character a byte when it is nil; the characters come from `table`.
    internal static func byteRow(
        _ index: Int,
        start: Int64,
        bytes: [UInt8],
        hex: HexFormat?,
        table: CodeTable
    ) -> Self {
        let span = start..<start + Int64(bytes.count)
        guard let hex else {
            let units = bytes.map { HexFormat.printable(table.single[Int($0)]) }
            return Self(
                index: index,
                range: span,
                contentEnd: span.upperBound,
                text: String(decoding: units, as: UTF16.self),
                offsets: bytes.indices.map(Int32.init),
                startsLine: true,
                line: index + 1
            )
        }
        return Self(
            index: index,
            range: span,
            contentEnd: span.upperBound,
            text: hex.line(offset: start, bytes: bytes, table: table),
            offsets: [],
            startsLine: true,
            line: index + 1
        )
    }
}
