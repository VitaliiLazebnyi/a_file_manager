import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// The size an XZ file states in its indexes, and the indexes that do not fit their file.
@Suite
internal struct CoverageArchivesFormatsXZSize {
    private let box: Sandbox

    /// A new folder for each test.
    internal init() throws {
        box = try Sandbox()
    }

    /// An XZ stream as far as its size is concerned: header, blocks of `packed` bytes, the
    /// index as given (padded, then `check`), and the footer.
    private func stream(
        index: [UInt8],
        packed: Int,
        check: [UInt8] = [0, 0, 0, 0],
        magic: [UInt8] = [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]
    ) -> Data {
        var data = Data(magic + [0, 0, 0, 0, 0, 0])
        data.append(Data(count: packed))
        var indexBytes = index
        while !indexBytes.count.isMultiple(of: 4) {
            indexBytes.append(0)
        }
        indexBytes += check
        data.append(contentsOf: indexBytes)
        var footer = Data([0, 0, 0, 0])
        footer.appendLE(UInt32(indexBytes.count / 4 - 1))
        footer.append(contentsOf: [0, 0, 0x59, 0x5A])
        data.append(footer)
        return data
    }

    /// A number as XZ writes it: seven bits per byte, the top bit set on all but the last.
    private func number(_ value: UInt64) -> [UInt8] {
        var (rest, bytes) = (value, [UInt8]())
        while rest >= 0x80 {
            bytes.append(UInt8(rest & 0x7F) | 0x80)
            rest >>= 7
        }
        return bytes + [UInt8(rest)]
    }

    private func size(_ data: Data) throws -> UInt64? {
        let url = box.url("\(UUID().uuidString).xz")
        try data.write(to: url)
        return CompressedSize.ofXZ(try RandomAccessFile(url, shownAs: nil))
    }

    /// The size comes from the index, also behind padding; an empty file has none.
    @Test
    internal func theSizeComesFromTheIndex() throws {
        let one = stream(index: [0, 1] + number(300) + number(70_000), packed: 300)
        #expect(try size(one) == 70_000)
        #expect(try size(one + Data(count: 8)) == 70_000)
        #expect(try size(Data()) == nil)
    }

    /// An index with more blocks than it has room for gives no size.
    @Test
    internal func moreBlocksThanTheIndexHoldsGiveNoSize() throws {
        #expect(try size(stream(index: [0, 9], packed: 0)) == nil)
    }

    /// A number that runs to the end of the index gives no size.
    @Test
    internal func aNumberThatNeverEndsGivesNoSize() throws {
        #expect(try size(stream(index: [0, 1, 0x80, 0x80], packed: 0, check: [0x80, 0x80, 0x80, 0x80])) == nil)
    }

    /// A block larger than the file gives no size.
    @Test
    internal func aBlockLargerThanTheFileGivesNoSize() throws {
        #expect(try size(stream(index: [0, 1] + number(1 << 40) + number(5), packed: 0)) == nil)
    }

    /// Sizes whose sum does not fit in 64 bits give no size.
    @Test
    internal func sizesWhoseSumOverflowsGiveNoSize() throws {
        let huge = number(UInt64(Int64.max))
        let records = [0, 3] + number(1) + huge + number(1) + huge + number(1) + huge
        #expect(try size(stream(index: records, packed: 12)) == nil)
    }

    /// Blocks that together are larger than the file give no size.
    @Test
    internal func blocksTogetherLargerThanTheFileGiveNoSize() throws {
        let length = number(UInt64(stream(index: [0, 1] + number(4) + number(4), packed: 4).count))
        #expect(try size(stream(index: [0, 2] + length + number(1) + length + number(1), packed: 0)) == nil)
    }

    /// A stream that does not begin like one gives no size.
    @Test
    internal func aStreamWithoutItsMagicGivesNoSize() throws {
        let wrong = stream(index: [0, 1] + number(4) + number(4), packed: 4, magic: [1, 2, 3, 4, 5, 6])
        #expect(try size(wrong) == nil)
    }
}
