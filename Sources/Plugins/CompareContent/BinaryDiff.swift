public import AFMKernel
public import Foundation

/// Two files compared byte by byte at the same offsets, in lines of a fixed number of bytes
/// (spec 09 › Loading, mode and encodings: binary mode).
public struct BinaryDiff: Equatable, Sendable {
    /// How many bytes make a line.
    public let bytesPerLine: Int
    /// The size of the left file in bytes.
    public let leftCount: Int
    /// The size of the right file in bytes.
    public let rightCount: Int
    /// The differences as ranges of lines.
    public let blocks: [Range<Int>]
    /// Bytes that differ, counting those one file has beyond the end of the other.
    public let differingBytes: Int

    /// How many lines the longer file makes.
    public var rowCount: Int { (max(leftCount, rightCount) + bytesPerLine - 1) / bytesPerLine }
    /// Whether no byte differs.
    public var isIdentical: Bool { differingBytes == 0 }

    /// Compares on all cores: the lines are dealt out in large pieces, and each piece reports
    /// its differing stretches.
    public static func compute(left: Data, right: Data, bytesPerLine: Int = 16, cancellation: CancellationFlag? = nil)
        -> Self
    {
        let width = max(1, bytesPerLine)
        let lines = (max(left.count, right.count) + width - 1) / width
        let pieceRows = max(4_096, lines / (ProcessInfo.processInfo.activeProcessorCount * 4) + 1)
        let pieces = stride(from: 0, to: lines, by: pieceRows).map { start in start..<min(start + pieceRows, lines) }

        let found: [(blocks: [Range<Int>], bytes: Int)] = left.withUnsafeBytes { leftBuffer in
            right.withUnsafeBytes { rightBuffer in
                // Only read, and only while the call lasts.
                nonisolated(unsafe) let (leftBytes, rightBytes) = (leftBuffer, rightBuffer)
                return Parallel.map(pieces) { piece in
                    scan(piece, leftBytes, rightBytes, width: width, cancellation: cancellation)
                }
            }
        }
        // Stretches that run across the border of two pieces are one difference.
        var joined: [Range<Int>] = []
        for block in found.flatMap(\.blocks) {
            if let last = joined.last, last.upperBound == block.lowerBound {
                joined[joined.count - 1] = last.lowerBound..<block.upperBound
            } else {
                joined.append(block)
            }
        }
        return Self(
            bytesPerLine: width,
            leftCount: left.count,
            rightCount: right.count,
            blocks: joined,
            differingBytes: found.reduce(0) { sum, piece in sum + piece.bytes }
        )
    }

    /// The differing stretches of lines in one piece, and how many bytes differ in it; cut short when
    /// `cancellation` is set.
    private static func scan(
        _ piece: Range<Int>,
        _ left: UnsafeRawBufferPointer,
        _ right: UnsafeRawBufferPointer,
        width: Int,
        cancellation: CancellationFlag?
    ) -> (blocks: [Range<Int>], bytes: Int) {
        var stretches: [Range<Int>] = []
        var bytes = 0
        var stretchStart: Int?
        for row in piece {
            if row & 0xFFF == 0, cancellation?.isCancelled == true {
                break
            }
            let differing = differingBytes(inLine: row, left, right, width: width)
            bytes += differing
            if differing > 0 {
                if stretchStart == nil {
                    stretchStart = row
                }
            } else if let begun = stretchStart {
                stretches.append(begun..<row)
                stretchStart = nil
            }
        }
        if let begun = stretchStart {
            stretches.append(begun..<piece.upperBound)
        }
        return (stretches, bytes)
    }

    /// How many bytes of a line differ, counting those one file has beyond the end of the other.
    private static func differingBytes(
        inLine row: Int,
        _ left: UnsafeRawBufferPointer,
        _ right: UnsafeRawBufferPointer,
        width: Int
    ) -> Int {
        let (lineStart, lineEnd) = (row * width, min((row + 1) * width, max(left.count, right.count)))
        let shared = max(0, min(lineEnd, min(left.count, right.count)) - lineStart)
        var differing = lineEnd - lineStart - shared
        // Both have bytes here, so both have an address.
        guard shared > 0, let leftBase = left.baseAddress, let rightBase = right.baseAddress,
            memcmp(leftBase + lineStart, rightBase + lineStart, shared) != 0
        else {
            return differing
        }
        for offset in lineStart..<(lineStart + shared) where left[offset] != right[offset] {
            differing += 1
        }
        return differing
    }

    /// The offset of a line's first byte, as shown in front of it.
    public func offsetText(row: Int) -> String {
        String(format: "%08X", row * bytesPerLine)
    }

    /// A line of one file: its bytes in hex, then as characters.
    ///
    /// Empty past the file's end.
    public func text(of data: Data, row: Int) -> String {
        let start = row * bytesPerLine
        guard start < data.count else {
            return ""
        }
        let bytes = data[(data.startIndex + start)..<(data.startIndex + min(start + bytesPerLine, data.count))]
        let digits = Array("0123456789ABCDEF".utf8)
        var text: [UInt8] = []
        text.reserveCapacity(bytesPerLine * 4 + 1)
        for (index, byte) in bytes.enumerated() {
            if index > 0 {
                text.append(0x20)
            }
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 15)])
        }
        while text.count < bytesPerLine * 3 + 1 {
            text.append(0x20)
        }
        for byte in bytes {
            text.append((0x20..<0x7F).contains(byte) ? byte : 0x2E)
        }
        // Hex digits, spaces and printable ASCII only: nothing needs repairing.
        return String(repairingUTF8: text)
    }

    /// The positions inside a line at which the two files differ.
    public func differingOffsets(left: Data, right: Data, row: Int) -> [Int] {
        let start = row * bytesPerLine
        return (0..<bytesPerLine)
            .filter { offset in
                let position = start + offset
                let (inLeft, inRight) = (position < left.count, position < right.count)
                if inLeft, inRight {
                    return left[left.startIndex + position] != right[right.startIndex + position]
                }
                return inLeft != inRight
            }
    }

    /// Where a byte of a line is in the line's text: its hex digits and its character.
    public func textRanges(ofByte offset: Int) -> [Range<Int>] {
        [(offset * 3)..<(offset * 3 + 2), (bytesPerLine * 3 + 1 + offset)..<(bytesPerLine * 3 + 2 + offset)]
    }
}
