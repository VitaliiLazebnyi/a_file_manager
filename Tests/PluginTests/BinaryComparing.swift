import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import CompareContentPlugin

/// Two files compared byte by byte at the same offsets, in lines of a fixed number of bytes.
@Suite
internal struct BinaryComparing {
    /// Bytes are compared at the same offsets, and the lines show hex and text.
    @Test
    internal func bytesAreComparedAtTheSameOffsets() {
        let left = Data((0..<40).map { UInt8($0) })
        var right = left
        right[3] = 0xFF
        right[17] = 0xEE
        right[18] = 0xEE
        right.append(contentsOf: [1, 2, 3])
        let diff = BinaryDiff.compute(left: left, right: right, bytesPerLine: 8)
        #expect(diff.rowCount == 6 && diff.differingBytes == 6 && !diff.isIdentical)
        #expect(diff.blocks == [0..<1, 2..<3, 5..<6])
        #expect(
            diff.differingOffsets(left: left, right: right, row: 2) == [1, 2]
                && diff.differingOffsets(left: left, right: right, row: 5) == [0, 1, 2]
        )
        #expect(diff.differingOffsets(left: left, right: right, row: 1).isEmpty)
        #expect(diff.offsetText(row: 2) == "00000010")
        #expect(diff.text(of: Data("Hello, W".utf8) + Data([0, 0xFF]), row: 0) == "48 65 6C 6C 6F 2C 20 57  Hello, W")
        #expect(diff.text(of: Data("Hello, W".utf8) + Data([0, 0xFF]), row: 1) == "00 FF                    ..")
        #expect(diff.text(of: left, row: 5).isEmpty)
        #expect(diff.textRanges(ofByte: 2) == [6..<8, 27..<28])
    }

    /// Empty files, one-sided files, equal files and slices of a larger buffer.
    @Test
    internal func edgeCases() {
        #expect(
            BinaryDiff.compute(left: Data(), right: Data()).isIdentical
                && BinaryDiff.compute(left: Data(), right: Data()).rowCount == 0
        )
        let one = BinaryDiff.compute(left: Data([1, 2, 3]), right: Data(), bytesPerLine: 16)
        #expect(one.blocks == [0..<1] && one.differingBytes == 3 && one.rowCount == 1)
        let same = BinaryDiff.compute(left: Data([9, 9]), right: Data([9, 9]), bytesPerLine: 1)
        #expect(same.isIdentical && same.blocks.isEmpty && same.rowCount == 2)
        // A slice of a larger buffer is addressed from its own start.
        let slice = Data([0, 0, 7, 8, 9]).dropFirst(2)
        let sliced = BinaryDiff.compute(left: slice, right: Data([7, 0, 9]), bytesPerLine: 2)
        #expect(
            sliced.differingOffsets(left: slice, right: Data([7, 0, 9]), row: 0) == [1]
                && sliced.text(of: slice, row: 1).hasPrefix("09")
        )
    }

    /// Large files are compared in pieces on all cores; differences across a piece border are one.
    @Test
    internal func largeFilesAreComparedInPiecesOnAllCores() {
        var random = DiffChecks.Seeded(state: 5)
        var left = Data(count: 3_000_000)
        left.withUnsafeMutableBytes { bytes in
            for index in stride(from: 0, to: bytes.count, by: 8) {
                bytes.storeBytes(of: random.next(), toByteOffset: index, as: UInt64.self)
            }
        }
        var right = left
        let changed = [0, 65_535, 65_536, 65_552, 1_500_000, 2_999_999]
        for offset in changed { right[offset] ^= 0x55 }
        let diff = BinaryDiff.compute(left: left, right: right, bytesPerLine: 16)
        #expect(diff.differingBytes == changed.count)
        // 65,535 and 65,536 are neighbouring lines across a piece border, and 65,552 is the next: one difference.
        #expect(diff.blocks == [0..<1, 4_095..<4_098, 93_750..<93_751, 187_499..<187_500])
        #expect(BinaryDiff.compute(left: left, right: left).isIdentical)
    }
}
