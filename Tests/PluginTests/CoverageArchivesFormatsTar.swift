import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// TAR headers and the reader of TAR archives, with the GNU and pax extensions.
@Suite
internal struct CoverageArchivesFormatsTar {
    private typealias Support = CoverageArchivesFormatsSupport

    /// A stream of nothing that notes whether it was closed.
    private final class ClosingStream: ByteStream {
        private(set) var isClosed = false

        func read(upToCount _: Int) -> Data? {
            nil
        }

        func close() {
            isClosed = true
        }

        deinit {
            // Nothing to release.
        }
    }

    /// A header block of the given type for `name`, with `size` bytes of data, changed by
    /// `change` before its checksum is made.
    private static func block(
        _ name: String,
        type: UInt8 = 48,
        size: UInt64 = 0,
        change: ((inout [UInt8]) -> Void)? = nil
    ) -> Data {
        var bytes = [UInt8](TarHeader(path: name, size: size).encoded())
        bytes[156] = type
        change?(&bytes)
        for index in 148..<156 {
            bytes[index] = 32
        }
        let digits = Array(String(bytes.reduce(0) { $0 + Int($1) }, radix: 8).utf8)
        bytes.replaceSubrange(148..<156, with: Array(repeating: UInt8(48), count: 6 - digits.count) + digits + [0, 32])
        return Data(bytes)
    }

    /// The data of a member, filled up to whole blocks.
    private static func body(_ data: Data) -> Data {
        data + TarHeader.padding(after: UInt64(data.count))
    }

    /// One pax record: its length counts itself.
    private static func record(_ key: String, _ value: String) -> Data {
        let body = " \(key)=\(value)\n"
        var length = body.utf8.count + 1
        while String(length).utf8.count + body.utf8.count != length {
            length = String(length).utf8.count + body.utf8.count
        }
        return Data("\(length)\(body)".utf8)
    }

    /// A pax extension header of type `type` (`x` or `g`) with its records.
    private static func extensionHeader(_ records: Data, type: UInt8 = 120) -> Data {
        block("PaxHeader", type: type, size: UInt64(records.count)) + body(records)
    }

    private static func reader(_ data: Data) -> TarReader {
        TarReader(DataStream(data), control: nil)
    }

    /// A block too short to be a header is none.
    @Test
    internal func aShortBlockIsNoHeader() {
        #expect(TarHeader.parse(Data(count: 100)) == nil)
    }

    /// Fields that are not what they claim fall back: names to plain text, numbers to their defaults.
    @Test
    internal func fieldsThatAreNoNumbersFallBackToDefaults() throws {
        let broken = Self.block("x") { bytes in
            bytes[1] = 0xFF
            bytes[100] = 0x39
            bytes[124] = 0x39
            bytes[136] = 0x39
        }
        let parsed = try #require(TarHeader.parse(broken))
        #expect(parsed.header.path == "x\u{FFFD}" && parsed.header.size == 0)
        #expect(parsed.header.modified == Date(timeIntervalSince1970: 0) && parsed.header.permissions == 0o644)
        // A plain file whose name ends in a slash is a folder.
        #expect(try #require(TarHeader.parse(Self.block("dir/", type: 0))).header.kind == .directory)
    }

    /// Links are written with their own types, and a long target in a pax record.
    @Test
    internal func linksAreWrittenWithTheirTypesAndLongTargets() throws {
        let target = String(repeating: "t", count: 150)
        var link = TarHeader(path: "link", kind: .symbolicLink)
        link.linkTarget = target
        let hard = TarHeader(path: "hard", kind: .hardLink, linkTarget: "link")
        let reader = Self.reader(link.encoded() + hard.encoded() + TarHeader.endOfArchive)
        let first = try #require(try reader.next())
        #expect(first.kind == .symbolicLink && first.linkTarget == target)
        let second = try #require(try reader.next())
        #expect(second.kind == .hardLink && second.linkTarget == "link")
        #expect(try reader.next() == nil)
    }

    /// An archive that ends without its two empty blocks ends after its last member.
    @Test
    internal func anArchiveWithoutItsEndMarkEndsAfterItsLastMember() throws {
        let reader = Self.reader(Self.block("a.txt", size: 3) + Self.body(Data("abc".utf8)))
        #expect(try reader.next()?.path == "a.txt")
        #expect(try reader.next() == nil)
    }

    /// A header cut off in the middle is damage.
    @Test
    internal func aHeaderCutOffIsDamage() {
        let reader = Self.reader(Self.block("a.txt").prefix(300))
        #expect(
            Support.failure { _ = try reader.next() }
                == ArchiveError.damaged("the TAR archive ends in the middle of a header").errorDescription
        )
    }

    /// An extension record that is too large, or cut off, is damage.
    @Test
    internal func extensionRecordsTooLargeOrCutOffAreDamage() {
        let large = Self.reader(Self.block("PaxHeader", type: 120, size: 1 << 25))
        #expect(
            Support.failure { _ = try large.next() }
                == ArchiveError.damaged("a TAR extension record is too large").errorDescription
        )
        let cut = Self.reader(Self.block("PaxHeader", type: 120, size: 100) + Data(count: 50))
        #expect(
            Support.failure { _ = try cut.next() }
                == ArchiveError.damaged("the TAR archive ends in the middle of a record").errorDescription
        )
    }

    /// GNU long names and link targets apply to the member that follows them.
    @Test
    internal func gnuLongNamesApplyToTheNextMember() throws {
        let name = String(repeating: "n", count: 120)
        let target = String(repeating: "l", count: 130)
        var data = Self.block("././@LongLink", type: 76, size: UInt64(name.utf8.count + 1))
        data += Self.body(Data(name.utf8) + Data([0]))
        data += Self.block("././@LongLink", type: 75, size: UInt64(target.utf8.count))
        data += Self.body(Data(target.utf8))
        data += Self.block("short", type: 50) + TarHeader.endOfArchive
        let member = try #require(try Self.reader(data).next())
        #expect(member.path == name && member.linkTarget == target && member.kind == .symbolicLink)
    }

    /// Pax records: the later of two wins, global ones are passed over, a link target and a
    /// folder's name come from them.
    @Test
    internal func paxRecordsNameLinksAndFolders() throws {
        var data = Self.extensionHeader(Self.record("comment", "global"), type: 103)
        data += Self.extensionHeader(Self.record("path", "first") + Self.record("linkpath", "old"))
        data += Self.extensionHeader(Self.record("path", "folder/") + Self.record("linkpath", "target"))
        data += Self.block("short") + TarHeader.endOfArchive
        let member = try #require(try Self.reader(data).next())
        #expect(member.path == "folder/" && member.linkTarget == "target" && member.kind == .directory)
    }

    /// The size of a sparse file comes from the GNU records that are there, or from its header.
    @Test
    internal func theSizeOfASparseFileComesFromWhatIsThere() throws {
        let old = Self.extensionHeader(Self.record("GNU.sparse.size", "4096")) + Self.block("old")
        let fromSize = try #require(try Self.reader(old + TarHeader.endOfArchive).next())
        #expect(fromSize.isSparse && fromSize.realSize == 4_096)
        let none = Self.extensionHeader(Self.record("GNU.sparse.major", "1")) + Self.block("none")
        let fromHeader = try #require(try Self.reader(none + TarHeader.endOfArchive).next())
        #expect(fromHeader.isSparse && fromHeader.realSize == nil)
    }

    /// An old GNU sparse file whose further blocks are missing is damage.
    @Test
    internal func aSparseFileWithoutItsFurtherBlocksIsDamage() {
        let reader = Self.reader(Self.block("sparse", type: 83) { $0[482] = 1 })
        #expect(
            Support.failure { _ = try reader.next() }
                == ArchiveError.damaged("the TAR archive ends in the middle of a header").errorDescription
        )
    }

    /// Data cut off in the middle of a member is damage; the member's stream then tells its
    /// owner that the reader cannot be used further.
    @Test
    internal func dataCutOffIsDamageAndSpoilsTheReader() throws {
        let reader = Self.reader(Self.block("a.txt", size: 600) + Data(count: 100))
        _ = try reader.next()
        let sound = SharedCounter()
        let member = TarMemberStream(reader, closesReader: false) { usable in sound.add(usable ? 1 : -1) }
        #expect(
            Support.failure { _ = try member.readFully(1_000) }
                == ArchiveError.damaged("the TAR archive ends in the middle of a file").errorDescription
        )
        member.close()
        member.close()
        #expect(sound.value == -1)
    }

    /// A member's stream that owns the reader closes it, and with it what the reader reads.
    @Test
    internal func aMembersStreamClosesTheReaderItOwns() {
        let source = ClosingStream()
        TarMemberStream(TarReader(source, control: nil), closesReader: true, onClose: nil).close()
        #expect(source.isClosed)
    }
}
