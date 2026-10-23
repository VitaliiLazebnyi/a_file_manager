import AFMKernel
import FileOperationsPlugin
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Crafted ZIP archives are refused, not crashed on: impossible offsets, sizes and extra fields.
@Suite
internal struct ArchiveCraftedZipFixes: ArchiveFixSuite {
    /// The archive file systems and the sandbox of the test.
    internal let bench: ArchiveBench

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// A ZIP whose directory has offsets beyond the file is damaged, not a crash; its member is refused when it is
    /// opened.
    @Test
    internal func aDirectoryWithImpossibleOffsetsIsDamaged() throws {
        func archive(offset: UInt64, stub: Int) throws -> URL {
            var central = Data()
            central.appendLE(UInt32(0x0201_4B50))
            for value in [UInt16(45), 45, 0, 0, 0, 0x21] { central.appendLE(value) }
            for value in [UInt32(0), 0, 0] { central.appendLE(value) }
            for value in [UInt16(1), 12, 0, 0, 0] { central.appendLE(value) }
            central.appendLE(UInt32(0))
            central.appendLE(UInt32(0xFFFF_FFFF))
            central.append(UInt8(ascii: "a"))
            central.appendLE(UInt16(1))
            central.appendLE(UInt16(8))
            central.appendLE(offset)
            var file = Data(count: stub)
            file.append(central)
            file.appendLE(UInt32(0x0605_4B50))
            for value in [UInt16(0), 0, 1, 1] { file.appendLE(value) }
            file.appendLE(UInt32(central.count))
            // The directory is said to start at 0 and starts behind the stub: every offset shifts.
            file.appendLE(UInt32(0))
            file.appendLE(UInt16(0))
            let url = box.url("crafted-\(stub)-\(offset % 7).zip")
            try file.write(to: url)
            return url
        }
        #expect(throws: ArchiveError.self) {
            try ZipDirectory.read(
                RandomAccessFile(archive(offset: .max, stub: 1), shownAs: nil),
                maxEntries: .max,
                check: nil
            )
        }
        #expect(throws: ArchiveError.self) { try bench.names(bench.inside(archive(offset: .max - 5, stub: 300))) }
        // Without a shift the directory can be read; the member is refused when it is opened.
        let plain = try archive(offset: .max, stub: 0)
        #expect(try bench.names(bench.inside(plain)) == ["a"])
        #expect(throws: ArchiveError.self) { try bench.read(bench.inside(plain, "a")) }
        let opened = try bench.store.archive(at: plain, cancellation: nil)
        #expect(ArchiveTester.test(opened, cancellation: CancellationFlag(), counter: nil, members: .all).count == 1)
    }
    /// Member sizes whose sum passes the largest number are added up without overflowing, for the listing, the
    /// unpacking
    /// and the test.
    @Test
    internal func sizesThatSumPastTheLargestNumberAreOnlyNumbers() throws {
        #expect(Int64.max.addingSaturated(5) == Int64.max)
        #expect(Int64(3).addingSaturated(4) == 7)
        #expect(UInt64.max.plusClamped(1) == UInt64.max)
        let archive = try writeZip("claims.zip") { writer in
            for index in 0..<3 {
                var record = ZipRecord.new(
                    name: "claim\(index).bin",
                    isDirectory: false,
                    modified: Date(),
                    permissions: 0o644,
                    isSymbolicLink: false
                )
                record.uncompressedSize = 1 << 62 + UInt64(index)
                try writer.copyMember(record, check: nil)
            }
        }
        let opened = try bench.store.archive(at: archive, cancellation: nil)
        #expect(opened.entries.map(\.size) == [1 << 62, 1 << 62 + 1, 1 << 62 + 2])
        // Unpacking and testing add the sizes up for their progress.
        let result = try bench.unpack(archive, to: box.url("claimed"))
        #expect(result.unpacked == 3 && !result.cancelled)
        #expect(bench.monitor.reports.last?.bytesTotal == .max)
        #expect(ArchiveTester.test(opened, cancellation: CancellationFlag(), counter: nil, members: .all).count == 3)
    }

    /// Extra fields that fill a ZIP entry make way for the time and ZIP64 fields instead of overflowing; a name too
    /// long
    /// for a header is an error.
    @Test
    internal func extraFieldsThatFillAnEntryMakeWayInsteadOfOverflowing() throws {
        // One field of nearly 64 KB, as the largest an entry can carry.
        var extra = Data()
        extra.appendLE(UInt16(0xCAFE))
        extra.appendLE(UInt16(0xFFFF - 4))
        extra.append(Data(repeating: 7, count: 0xFFFF - 4))
        var record = ZipRecord()
        record.nameBytes = Data("full.txt".utf8)
        record.extra = extra
        // The time field no longer fits beside it: the old field goes.
        var dated = record
        dated.setModified(Date(timeIntervalSince1970: 1_650_000_000))
        #expect(dated.extra.count == 9 && dated.modified == Date(timeIntervalSince1970: 1_650_000_000))
        // The 64-bit field no longer fits beside it either, in both headers.
        let limits = ZipLimits(maxField: 10, maxEntries: 100)
        let archive = try writeZip("full.zip", limits: limits) { writer in
            try writer.copyMember(record, check: nil)
            var large = record
            large.uncompressedSize = 500
            try writer.copyMember(large, check: nil)
            try writer.copyMember(dated, check: nil)
        }
        let contents = try ZipDirectory.read(RandomAccessFile(archive, shownAs: nil), maxEntries: .max, check: nil)
        #expect(
            contents.records.map(\.uncompressedSize) == [0, 500, 0]
                && contents.records.map(\.extra.count) == [0xFFFF, 0, 9]
        )
        // A name longer than a header can say is an error, not a crash.
        var long = ZipRecord()
        long.nameBytes = Data(repeating: 97, count: 70_000)
        #expect(throws: ArchiveError.self) { try writeZip("long.zip") { try $0.copyMember(long, check: nil) } }
        // A stretch that reaches past the end of the file ends with the file.
        let file = try RandomAccessFile(archive, shownAs: nil)
        let stream = FileRangeStream(file, offset: file.size - 2, length: .max)
        #expect(try stream.read(upToCount: 100)?.count == 2)
        #expect(throws: ArchiveError.self) { try FileRangeStream(file, offset: .max, length: .max).skip(1) }
    }
}
