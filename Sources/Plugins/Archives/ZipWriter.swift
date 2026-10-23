import Foundation

/// Writes a ZIP archive front to back: members, then the directory.
///
/// Used by one thread.
internal final class ZipWriter {
    /// A member whose header was written and whose data is being appended.
    internal struct OpenMember {
        /// Where the member's local header starts.
        internal let offset: UInt64
        /// Whether the header has room for 64-bit sizes.
        internal let wide: Bool
        /// The extra fields of the local header, written again with the final values.
        internal let localExtra: Data
    }

    private let output: OutputFile
    private let limits: ZipLimits
    private var written: [(record: ZipRecord, offset: UInt64)] = []
    /// True once anything needed the 64-bit format.
    internal private(set) var usedZip64 = false

    /// A writer that appends to `output`; `limits` says when the 64-bit format is needed.
    internal init(_ output: OutputFile, limits: ZipLimits) {
        self.output = output
        self.limits = limits
    }

    private static func nameLength(of record: ZipRecord) throws -> UInt16 {
        guard let length = UInt16(exactly: record.nameLength) else {
            throw ArchiveError.unsupported("A name of more than 65535 bytes")
        }
        return length
    }

    private func localHeader(_ record: ZipRecord, wide: Bool, extra: Data) throws -> Data {
        let nameLength = try Self.nameLength(of: record)
        var header = Data()
        header.appendLE(ZipDirectory.localSignature)
        header.appendLE(UInt16(wide ? 45 : record.method == 0 && !record.isEncrypted ? 10 : 20))
        header.appendLE(record.flags)
        header.appendLE(record.method)
        header.appendLE(record.dosTime)
        header.appendLE(record.dosDate)
        header.appendLE(record.crc)
        header.appendLE(wide ? UInt32(0xFFFF_FFFF) : UInt32(truncatingIfNeeded: record.compressedSize))
        header.appendLE(wide ? UInt32(0xFFFF_FFFF) : UInt32(truncatingIfNeeded: record.uncompressedSize))
        var fields = Data()
        if wide {
            fields.appendLE(UInt16(1))
            fields.appendLE(UInt16(16))
            fields.appendLE(record.uncompressedSize)
            fields.appendLE(record.compressedSize)
        }
        fields.append(ZipRecord.fitting(extra, into: 0xFFFF - fields.count))
        header.appendLE(nameLength)
        header.appendLE(UInt16(fields.count))
        header.append(record.nameBytes)
        header.append(fields)
        return header
    }

    /// Starts a member.
    ///
    /// With `expectedSize` the sizes need not be known yet: room for 64-bit sizes is reserved when
    /// the member may grow past the 32-bit fields, and `end` fills in the real values.
    internal func begin(_ record: ZipRecord, localExtra: Data?, expectedSize: UInt64?) throws -> OpenMember {
        let largest = max(record.uncompressedSize, record.compressedSize, expectedSize.map { $0 + $0 / 8 + 1_024 } ?? 0)
        let member = OpenMember(
            offset: output.position,
            wide: largest > limits.maxField,
            localExtra: localExtra ?? record.extra
        )
        try output.write(try localHeader(record, wide: member.wide, extra: member.localExtra))
        return member
    }

    /// Lists a member that already lies in the file this writer continues, at `offset`.
    internal func adopt(_ record: ZipRecord, at offset: UInt64) {
        written.append((record, offset))
    }

    /// Replaces bytes written earlier, also in the part of the file that was there before.
    internal func patch(_ data: Data, at offset: UInt64) throws {
        try output.rewrite(data, at: offset)
    }

    /// Appends data of the member that is open.
    internal func append(_ data: Data) throws {
        try output.write(data)
    }

    /// Ends a member with its final values, which replace those written by `begin`.
    internal func end(_ member: OpenMember, _ record: ZipRecord, headerChanged: Bool) throws {
        guard member.wide || max(record.compressedSize, record.uncompressedSize) <= limits.maxField else {
            throw ArchiveError.unsupported("A file that grew past 4 GB while it was packed")
        }
        if headerChanged {
            try output.rewrite(
                try localHeader(record, wide: member.wide, extra: member.localExtra),
                at: member.offset
            )
        }
        if record.flags & ZipRecord.flagDescriptor != 0 {
            var descriptor = Data()
            descriptor.appendLE(UInt32(0x0807_4B50))
            descriptor.appendLE(record.crc)
            if member.wide {
                descriptor.appendLE(record.compressedSize)
                descriptor.appendLE(record.uncompressedSize)
            } else {
                descriptor.appendLE(UInt32(record.compressedSize))
                descriptor.appendLE(UInt32(record.uncompressedSize))
            }
            try output.write(descriptor)
        }
        if member.wide { usedZip64 = true }
        written.append((record, member.offset))
    }

    /// Writes the directory and the end records.
    internal func finish(comment: Data) throws {
        let directoryOffset = output.position
        for (record, offset) in written {
            try output.write(try centralHeader(of: record, at: offset))
        }
        let directorySize = output.position - directoryOffset
        let needs64 =
            written.count > limits.maxEntries || directorySize > limits.maxField || directoryOffset > limits.maxField
        if needs64 {
            usedZip64 = true
            try output.write(end64Records(directorySize: directorySize, directoryOffset: directoryOffset))
        }
        try output.write(endRecord(directorySize: directorySize, directoryOffset: directoryOffset, comment: comment))
    }

    /// The directory's record of a member whose local header lies at `offset`.
    private func centralHeader(of record: ZipRecord, at offset: UInt64) throws -> Data {
        var wide = Data()
        if record.uncompressedSize > limits.maxField { wide.appendLE(record.uncompressedSize) }
        if record.compressedSize > limits.maxField { wide.appendLE(record.compressedSize) }
        if offset > limits.maxField { wide.appendLE(offset) }
        var fields = Data()
        if !wide.isEmpty {
            fields.appendLE(UInt16(1))
            fields.appendLE(UInt16(wide.count))
            fields.append(wide)
        }
        fields.append(ZipRecord.fitting(record.extra, into: 0xFFFF - fields.count))
        let nameLength = try Self.nameLength(of: record)
        var header = Data()
        header.reserveCapacity(46 + record.nameLength + fields.count + 16)
        header.appendLE(UInt32(0x0201_4B50))
        header.appendLE(record.versionMadeBy)
        header.appendLE(UInt16(wide.isEmpty ? (record.method == 0 && !record.isEncrypted ? 10 : 20) : 45))
        header.appendLE(record.flags)
        header.appendLE(record.method)
        header.appendLE(record.dosTime)
        header.appendLE(record.dosDate)
        header.appendLE(record.crc)
        header.appendLE(record.compressedSize > limits.maxField ? UInt32(0xFFFF_FFFF) : UInt32(record.compressedSize))
        header.appendLE(
            record.uncompressedSize > limits.maxField ? UInt32(0xFFFF_FFFF) : UInt32(record.uncompressedSize)
        )
        header.appendLE(nameLength)
        header.appendLE(UInt16(fields.count))
        header.appendLE(UInt16(truncatingIfNeeded: min(record.comment.count, 0xFFFF)))
        header.appendLE(UInt16(0))
        header.appendLE(record.internalAttributes)
        header.appendLE(record.externalAttributes)
        header.appendLE(offset > limits.maxField ? UInt32(0xFFFF_FFFF) : UInt32(offset))
        header.append(record.nameBytes)
        header.append(fields)
        header.append(record.comment.prefix(0xFFFF))
        return header
    }

    /// The 64-bit end record and its locator, written where the output stands.
    private func end64Records(directorySize: UInt64, directoryOffset: UInt64) -> Data {
        let end64Offset = output.position
        var records = Data()
        records.appendLE(UInt32(0x0606_4B50))
        records.appendLE(UInt64(44))
        records.appendLE(UInt16(45))
        records.appendLE(UInt16(45))
        records.appendLE(UInt32(0))
        records.appendLE(UInt32(0))
        records.appendLE(UInt64(written.count))
        records.appendLE(UInt64(written.count))
        records.appendLE(directorySize)
        records.appendLE(directoryOffset)
        records.appendLE(UInt32(0x0706_4B50))
        records.appendLE(UInt32(0))
        records.appendLE(end64Offset)
        records.appendLE(UInt32(1))
        return records
    }

    /// The classic end record, with the values that do not fit marked as in the 64-bit record.
    private func endRecord(directorySize: UInt64, directoryOffset: UInt64, comment: Data) -> Data {
        var record = Data()
        record.appendLE(UInt32(0x0605_4B50))
        record.appendLE(UInt16(0))
        record.appendLE(UInt16(0))
        let count = written.count > limits.maxEntries ? UInt16(0xFFFF) : UInt16(written.count)
        record.appendLE(count)
        record.appendLE(count)
        record.appendLE(directorySize > limits.maxField ? UInt32(0xFFFF_FFFF) : UInt32(directorySize))
        record.appendLE(directoryOffset > limits.maxField ? UInt32(0xFFFF_FFFF) : UInt32(directoryOffset))
        record.appendLE(UInt16(min(comment.count, 0xFFFF)))
        record.append(comment.prefix(0xFFFF))
        return record
    }

    deinit {
        // Nothing to release.
    }
}
