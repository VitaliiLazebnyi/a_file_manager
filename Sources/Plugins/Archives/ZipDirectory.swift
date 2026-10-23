import Foundation

/// Reads the directory of a ZIP archive.
///
/// Only the end of the file is read, however large the archive is: the members' data is touched
/// when one of them is opened.
internal enum ZipDirectory {
    /// What the directory of an archive holds.
    internal struct Contents {
        /// The members in the order of the directory (empty after `scan`, which hands them out).
        internal var records: [ZipRecord]
        /// The archive's comment from the end record.
        internal var comment: Data
        /// True when the archive uses the 64-bit end records.
        internal var isZip64: Bool
        /// Where the directory starts in the file: the members lie in front of it.
        internal var directoryOffset: UInt64
    }

    /// The values of the end records that the directory is found with.
    internal struct EndRecord {
        /// How many members the directory says it holds.
        internal var entryCount: UInt64
        /// The size of the directory in bytes.
        internal var directorySize: UInt64
        /// Where the directory starts as the archive stores it (too small behind a self-extracting
        /// program).
        internal var directoryOffset: UInt64
        /// Where the directory ends in the file: at the end record, or at the 64-bit end record.
        internal var directoryEnd: UInt64
        /// The archive's comment.
        internal var comment: Data
        /// True when a 64-bit end record gave the values.
        internal var isZip64: Bool
    }

    private static let end64Signature: UInt32 = 0x0606_4B50
    private static let locator64Signature: UInt32 = 0x0706_4B50
    private static let centralSignature: UInt32 = 0x0201_4B50
    /// The signature in front of every member's local header.
    internal static let localSignature: UInt32 = 0x0403_4B50

    /// `maxEntries` bounds what is read into memory; `check` is called now and then while a
    /// long directory is read, and may throw to end the reading.
    internal static func read(_ file: RandomAccessFile, maxEntries: Int, check: (() throws -> Void)?)
        throws
        -> Contents
    {
        var records: [ZipRecord] = []
        var contents = try scan(
            file,
            maxEntries: maxEntries,
            check: check,
            expecting: { records.reserveCapacity($0) },
            { records.append($0) }
        )
        contents.records = records
        return contents
    }

    /// Reads the directory and hands its records to `each` one by one, in their order, so
    /// that a caller who keeps them in a form of its own never holds a second list of them;
    /// the result has no records.
    ///
    /// `expecting` hears beforehand how many there will be at most. A directory that turns out to
    /// be damaged throws after some records were handed out.
    internal static func scan(
        _ file: RandomAccessFile,
        maxEntries: Int,
        check: (() throws -> Void)?,
        expecting: (Int) -> Void,
        _ each: (ZipRecord) throws -> Void
    ) throws -> Contents {
        let end = try endRecord(of: file)
        guard end.directorySize <= end.directoryEnd else {
            throw ArchiveError.damaged("the ZIP directory is larger than the file")
        }
        // Data in front of the archive (a self-extracting program) shifts every offset.
        let actualStart = end.directoryEnd - end.directorySize
        let shift = actualStart >= end.directoryOffset ? actualStart - end.directoryOffset : 0
        guard end.directorySize <= 1 << 31 else {
            throw ArchiveError.unsupported("A ZIP directory of more than 2 GB")
        }
        // (A file that has become shorter since it was opened delivers less: then the count of
        // records below does not fit.)
        let directory = try file.read(at: actualStart, count: Int(end.directorySize))

        var count = 0
        // No more than the directory has room for, whatever the end record claims.
        expecting(Int(min(end.entryCount, end.directorySize / 46, UInt64(clamping: maxEntries))))
        var reader = ByteReader(directory)
        while reader.remaining >= 46 {
            guard reader.u32() == centralSignature else { break }
            guard count < maxEntries else {
                throw ArchiveError.unsupported("An archive with more than \(maxEntries) entries")
            }
            if count & 0x1FFF == 0x1FFF { try check?() }
            let record = try centralRecord(from: &reader, in: file, shiftedBy: shift)
            count += 1
            try each(record)
        }
        guard UInt64(count) == end.entryCount || end.entryCount == 0xFFFF else {
            throw ArchiveError.damaged("the ZIP directory lists \(end.entryCount) files but holds \(count)")
        }
        return Contents(records: [], comment: end.comment, isZip64: end.isZip64, directoryOffset: actualStart)
    }

    /// Where the end record starts in `tail`, the last bytes of the file; nil when there is none.
    private static func endRecordIndex(in tail: Data) -> Int? {
        var index = tail.count - 22
        while index >= 0 {
            if tail[index] == 0x50, tail[index + 1] == 0x4B, tail[index + 2] == 0x05, tail[index + 3] == 0x06 {
                let commentLength = Int(tail[index + 20]) | Int(tail[index + 21]) << 8
                // A comment longer than what follows: the signature is part of a comment, the record is
                // further back.
                if index + 22 + commentLength <= tail.count {
                    return index
                }
            }
            index -= 1
        }
        return nil
    }

    /// What the end records of the archive say: the classic one, and the 64-bit one where it is.
    private static func endRecord(of file: RandomAccessFile) throws -> EndRecord {
        // The end record is the last thing in the file, followed only by a comment of up to 64 KB.
        let tailSize = Int(min(file.size, 22 + 0xFFFF))
        let tailStart = file.size - UInt64(tailSize)
        let tail = try file.read(at: tailStart, count: tailSize)
        guard tail.count >= 22 else { throw ArchiveError.damaged("the file is too short for a ZIP archive") }
        guard let endIndex = endRecordIndex(in: tail) else {
            throw ArchiveError.damaged("the ZIP directory was not found")
        }
        var reader = ByteReader(tail.subdata(in: endIndex..<tail.count))
        _ = reader.u32()
        let (disk, directoryDisk) = (reader.u16(), reader.u16())
        _ = reader.u16()
        var end = EndRecord(
            entryCount: UInt64(reader.u16()),
            directorySize: UInt64(reader.u32()),
            directoryOffset: UInt64(reader.u32()),
            directoryEnd: tailStart + UInt64(endIndex),
            comment: Data(),
            isZip64: false
        )
        end.comment = reader.bytes(Int(reader.u16()))
        guard disk == directoryDisk else { throw ArchiveError.unsupported("An archive split over several disks") }
        try readZip64(of: file, into: &end)
        return end
    }

    /// Takes the values of the 64-bit end record, when its locator stands in front of the end record.
    ///
    /// The directory then ends at the 64-bit record.
    private static func readZip64(of file: RandomAccessFile, into end: inout EndRecord) throws {
        guard end.directoryEnd >= 20 else {
            return
        }
        var locator = ByteReader(try file.read(at: end.directoryEnd - 20, count: 20))
        guard locator.u32() == locator64Signature else {
            return
        }
        _ = locator.u32()
        var end64Offset = locator.u64()
        var end64 = ByteReader(try file.read(at: end64Offset, count: 56))
        var found = end64.u32() == end64Signature
        if !found, end.directoryEnd >= 76 {
            // Behind a self-extracting program every stored offset is too small by the
            // program's length; the record itself lies right in front of its locator.
            end64Offset = end.directoryEnd - 76
            end64 = ByteReader(try file.read(at: end64Offset, count: 56))
            found = end64.u32() == end64Signature
        }
        if found {
            _ = end64.u64()
            _ = end64.u32()
            _ = end64.u64()
            _ = end64.u64()
            end.entryCount = end64.u64()
            end.directorySize = end64.u64()
            end.directoryOffset = end64.u64()
            end.directoryEnd = end64Offset
            end.isZip64 = true
        }
    }

    /// One record of the central directory, read from behind its signature; `shift` is added to
    /// the offset of its header.
    private static func centralRecord(
        from reader: inout ByteReader,
        in file: RandomAccessFile,
        shiftedBy shift: UInt64
    ) throws -> ZipRecord {
        var record = ZipRecord()
        record.versionMadeBy = reader.u16()
        _ = reader.u16()
        record.flags = reader.u16()
        record.method = reader.u16()
        record.dosTime = reader.u16()
        record.dosDate = reader.u16()
        record.crc = reader.u32()
        record.compressedSize = UInt64(reader.u32())
        record.uncompressedSize = UInt64(reader.u32())
        let (nameLength, extraLength, commentLength) = (Int(reader.u16()), Int(reader.u16()), Int(reader.u16()))
        _ = reader.u16()
        record.internalAttributes = reader.u16()
        record.externalAttributes = reader.u32()
        var offset = UInt64(reader.u32())
        guard reader.remaining >= nameLength + extraLength + commentLength else {
            throw ArchiveError.damaged("the ZIP directory is cut off")
        }
        record.nameBytes = reader.bytes(nameLength)
        let extra = reader.bytes(extraLength)
        record.comment = reader.bytes(commentLength)
        // The 64-bit field holds, in this order, exactly the values that did not fit.
        if let field = ZipRecord.field(1, in: extra) {
            var wide = ByteReader(field)
            if record.uncompressedSize == 0xFFFF_FFFF, wide.remaining >= 8 { record.uncompressedSize = wide.u64() }
            if record.compressedSize == 0xFFFF_FFFF, wide.remaining >= 8 { record.compressedSize = wide.u64() }
            if offset == 0xFFFF_FFFF, wide.remaining >= 8 { offset = wide.u64() }
        }
        record.extra = ZipRecord.removing(1, from: extra)
        let (headerOffset, overflow) = offset.addingReportingOverflow(shift)
        guard !overflow else { throw ArchiveError.damaged("the entry \(record.name) lies outside the file") }
        record.source = .archive(headerOffset: headerOffset, file: file)
        return record
    }

    /// Reads a member's local header: where its data starts, and its own extra fields
    /// (without the 64-bit field).
    internal static func localHeader(of record: ZipRecord, at offset: UInt64, in file: RandomAccessFile) throws -> (
        dataOffset: UInt64, extra: Data
    ) {
        // An offset inside the file also keeps the sums below far from the end of the numbers.
        guard offset < file.size else { throw ArchiveError.damaged("the entry \(record.name) lies outside the file") }
        var header = ByteReader(try file.read(at: offset, count: 30))
        guard header.u32() == localSignature else {
            throw ArchiveError.damaged("the entry \(record.name) is not where the directory says")
        }
        header.position = 26
        let (nameLength, extraLength) = (UInt64(header.u16()), Int(header.u16()))
        let extra = try file.read(at: offset + 30 + nameLength, count: extraLength)
        return (offset + 30 + nameLength + UInt64(extraLength), ZipRecord.removing(1, from: extra))
    }
}
