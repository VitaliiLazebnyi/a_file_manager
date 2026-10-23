import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// The directory of a ZIP archive as it is read, and as `ZipWriter` writes it.
@Suite
internal struct CoverageArchivesFormatsZipDirectory {
    private typealias Support = CoverageArchivesFormatsSupport

    private let box: Sandbox

    /// A new folder for each test.
    internal init() throws {
        box = try Sandbox()
    }

    /// A ZIP of stored members, written by `ZipPacker`.
    private func zip(
        _ members: [(name: String, text: String)],
        password: String? = nil,
        limits: ZipLimits = .standard,
        comment: Data = Data()
    ) throws -> URL {
        let url = box.url("\(UUID().uuidString).zip")
        let output = try OutputFile(creating: url, mode: 0o600)
        let packer = ZipPacker(output, level: 0, password: password, encryption: .legacy, limits: limits)
        for member in members {
            let record = ZipRecord.new(
                name: member.name,
                isDirectory: false,
                modified: Date(),
                permissions: 0o644,
                isSymbolicLink: false
            )
            var sent = false
            try packer.add(record, expectedSize: UInt64(member.text.utf8.count), stored: false) {
                defer { sent = true }
                return sent ? nil : Data(member.text.utf8)
            }
        }
        try packer.finish(comment: comment)
        try output.close(durably: false)
        return url
    }

    /// Changes the bytes of `url` at `offset` from its end record (`end`: 22 bytes before the
    /// comment) or from its start.
    private func patch(_ url: URL, at offset: Int, _ bytes: [UInt8], fromEnd comment: Int? = nil) throws {
        var data = try Data(contentsOf: url)
        let start = comment.map { data.count - 22 - $0 + offset } ?? offset
        data.replaceSubrange(start..<(start + bytes.count), with: bytes)
        try data.write(to: url)
    }

    private func directory(_ url: URL) throws -> ZipDirectory.Contents {
        try ZipDirectory.read(try RandomAccessFile(url, shownAs: nil), maxEntries: .max, check: nil)
    }

    private func failure(_ url: URL) -> String? {
        Support.failure { _ = try directory(url) }
    }

    /// A file without an end record has no ZIP directory.
    @Test
    internal func aFileWithoutAnEndRecordHasNoDirectory() throws {
        let url = box.url("none.zip")
        try Data(count: 100).write(to: url)
        #expect(failure(url) == ArchiveError.damaged("the ZIP directory was not found").errorDescription)
    }

    /// Something that only looks like an end record in the comment is passed over.
    @Test
    internal func anEndRecordInTheCommentIsPassedOver() throws {
        var comment = Data([0x50, 0x4B, 0x05, 0x06])
        comment.append(Data(count: 16))
        comment.append(contentsOf: [0xFF, 0xFF])
        comment.append(Data(count: 8))
        let contents = try directory(try zip([("a.txt", "abc")], comment: comment))
        #expect(contents.comment == comment && contents.records.map(\.name) == ["a.txt"])
    }

    /// An archive split over several disks is not supported.
    @Test
    internal func anArchiveOverSeveralDisksIsNotSupported() throws {
        let url = try zip([("a.txt", "abc")])
        try patch(url, at: 4, [1, 0], fromEnd: 0)
        #expect(failure(url) == ArchiveError.unsupported("An archive split over several disks").errorDescription)
    }

    /// A directory larger than the file is damage.
    @Test
    internal func aDirectoryLargerThanTheFileIsDamage() throws {
        let url = try zip([("a.txt", "abc")])
        try patch(url, at: 12, [0xFF, 0xFF, 0xFF, 0x7F], fromEnd: 0)
        #expect(failure(url) == ArchiveError.damaged("the ZIP directory is larger than the file").errorDescription)
    }

    /// A directory that says it starts later than it does shifts nothing.
    @Test
    internal func aDirectoryOffsetTooLargeShiftsNothing() throws {
        let url = try zip([("a.txt", "abc")])
        try patch(url, at: 16, [0xFF, 0xFF, 0, 0], fromEnd: 0)
        let contents = try directory(url)
        #expect(contents.records.map(\.headerOffset) == [0])
    }

    /// A directory of more than 2 GB is not read.
    @Test
    internal func aDirectoryOfMoreThan2GBIsNotRead() throws {
        // A file of 3 GB that is all hole, with an end record at its end.
        let url = box.url("huge.zip")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 3 << 30)
        try handle.seekToEnd()
        var end = Data()
        end.appendLE(UInt32(0x0605_4B50))
        end.append(Data(count: 4))
        end.appendLE(UInt16(1))
        end.appendLE(UInt16(1))
        end.appendLE(UInt32(0x8000_0001))
        end.appendLE(UInt32(0))
        end.appendLE(UInt16(0))
        try handle.write(contentsOf: end)
        try handle.close()
        #expect(failure(url) == ArchiveError.unsupported("A ZIP directory of more than 2 GB").errorDescription)
    }

    /// A directory whose first record is no record lists nothing, which does not fit its count.
    @Test
    internal func aRecordWithoutItsSignatureEndsTheDirectory() throws {
        let url = try zip([("a.txt", "abc")])
        let start = Int(try directory(url).directoryOffset)
        try patch(url, at: start, [0, 0, 0, 0])
        #expect(
            failure(url)
                == ArchiveError.damaged("the ZIP directory lists 1 files but holds 0").errorDescription
        )
    }

    /// A count of 65535 in the end record is taken as "more than the record can count".
    @Test
    internal func theLargestCountIsTakenAsUnknown() throws {
        let url = try zip([("a.txt", "abc")])
        try patch(url, at: 8, [0xFF, 0xFF, 0xFF, 0xFF], fromEnd: 0)
        #expect(try directory(url).records.count == 1)
    }

    /// A record whose name runs past the directory is damage.
    @Test
    internal func aNameThatRunsPastTheDirectoryIsDamage() throws {
        let url = try zip([("a.txt", "abc")])
        let start = Int(try directory(url).directoryOffset)
        try patch(url, at: start + 28, [0xFF, 0xFF])
        #expect(failure(url) == ArchiveError.damaged("the ZIP directory is cut off").errorDescription)
    }

    /// A member whose header is not where the directory says is damage.
    @Test
    internal func aHeaderThatIsNotThereIsDamage() throws {
        let url = try zip([("a.txt", "abc")])
        let file = try RandomAccessFile(url, shownAs: nil)
        let record = try #require(try ZipDirectory.read(file, maxEntries: .max, check: nil).records.first)
        #expect(
            Support.failure { _ = try ZipDirectory.localHeader(of: record, at: 1, in: file) }
                == ArchiveError.damaged("the entry a.txt is not where the directory says").errorDescription
        )
    }

    // MARK: Writing

    /// Members whose sizes pass the 32-bit fields get the 64-bit fields, also in the
    /// descriptor that follows a traditionally encrypted member, and read back.
    @Test
    internal func largeMembersGetTheWideFieldsEverywhere() throws {
        let limits = ZipLimits(maxField: 4, maxEntries: 0xFFFE)
        let url = try zip([("a.txt", "some text")], password: "pw", limits: limits)
        let file = try RandomAccessFile(url, shownAs: nil)
        let contents = try ZipDirectory.read(file, maxEntries: .max, check: nil)
        let record = try #require(contents.records.first)
        #expect(record.uncompressedSize == 9 && record.compressedSize == UInt64(9 + ZipCrypto.headerSize))
        let header = try ZipDirectory.localHeader(of: record, at: 0, in: file)
        // The data, then a descriptor of signature, checksum and two 64-bit sizes.
        #expect(contents.directoryOffset == header.dataOffset + record.compressedSize + 24)
        let stream = try ZipDecryptStream(
            FileRangeStream(file, offset: header.dataOffset, length: record.compressedSize),
            password: "pw",
            check: UInt8(record.dosTime >> 8),
            name: record.name
        )
        #expect(try stream.readFully(100) == Data("some text".utf8))
    }

    /// A member that grew past the 32-bit fields after its header was written without room
    /// for them cannot be ended.
    @Test
    internal func aMemberThatGrewPastTheFieldsCannotBeEnded() throws {
        let output = try OutputFile(creating: box.url("grown.zip"), mode: 0o600)
        let writer = ZipWriter(output, limits: ZipLimits(maxField: 4, maxEntries: 10))
        var record = ZipRecord.new(
            name: "a",
            isDirectory: false,
            modified: Date(),
            permissions: 0o644,
            isSymbolicLink: false
        )
        let member = try writer.begin(record, localExtra: nil, expectedSize: nil)
        record.uncompressedSize = 100
        #expect(
            Support.failure { try writer.end(member, record, headerChanged: true) }
                == ArchiveError.unsupported("A file that grew past 4 GB while it was packed").errorDescription
        )
        try output.close(durably: false)
    }

    /// A member whose waiting data is shorter than its record says is not copied.
    @Test
    internal func aMemberWhoseDataIsCutOffIsNotCopied() throws {
        let spooled = try box.file("spool.bin", "12345")
        var record = ZipRecord.new(
            name: "m",
            isDirectory: false,
            modified: Date(),
            permissions: 0o644,
            isSymbolicLink: false
        )
        record.source = .spool(TemporaryFile(spooled))
        record.compressedSize = 10
        let output = try OutputFile(creating: box.url("copy.zip"), mode: 0o600)
        let writer = ZipWriter(output, limits: .standard)
        #expect(
            Support.failure { try writer.copyMember(record, check: nil) }
                == ArchiveError.damaged("the data of m is cut off").errorDescription
        )
        try output.close(durably: false)
    }
}
