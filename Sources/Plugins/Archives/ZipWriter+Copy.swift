import Foundation

/// Copying members from one archive into another.
extension ZipWriter {
    /// Copies a member into the new archive without recompressing it, from the archive or the
    /// temporary file it lies in.
    ///
    /// Returns where its header was written. `check` is called between the blocks of a large member
    /// and may throw to end the copy.
    @discardableResult
    internal func copyMember(_ record: ZipRecord, check: (() throws -> Void)?) throws -> UInt64 {
        var localExtra = record.extra
        var data: any ByteStream?
        switch record.source {
        case .archive(let headerOffset, let file):
            let header = try ZipDirectory.localHeader(of: record, at: headerOffset, in: file)
            localExtra = header.extra
            data = FileRangeStream(file, offset: header.dataOffset, length: record.compressedSize)

        case .spool(let temporary):
            data = FileRangeStream(
                try RandomAccessFile(temporary.url, shownAs: nil),
                offset: 0,
                length: record.compressedSize
            )

        case .nowhere:
            break
        }
        // The fields that say the same in both headers follow the directory: the name and the
        // time may have been changed here.
        for id in [UInt16(0x5455), 0x7075] {
            localExtra = ZipRecord.removing(id, from: localExtra)
            if let field = ZipRecord.field(id, in: record.extra) {
                localExtra.appendLE(id)
                localExtra.appendLE(UInt16(field.count))
                localExtra.append(field)
            }
        }
        let member = try begin(record, localExtra: localExtra, expectedSize: nil)
        var copied: UInt64 = 0
        while let block = try data?.read(upToCount: 1 << 20) {
            try check?()
            try append(block)
            copied += UInt64(block.count)
        }
        guard copied == record.compressedSize else {
            throw ArchiveError.damaged("the data of \(record.name) is cut off")
        }
        try end(member, record, headerChanged: false)
        return member.offset
    }
}
