import AFMKernel
import Foundation

/// Reading the members of a ZIP.
extension OpenArchive {
    /// The stored bytes of a member, as they lie in the archive file or wait in a temporary file.
    private static func raw(_ record: ZipRecord) throws -> any ByteStream {
        switch record.source {
        case .archive(let headerOffset, let file):
            let dataOffset = try ZipDirectory.localHeader(of: record, at: headerOffset, in: file).dataOffset
            return FileRangeStream(file, offset: dataOffset, length: record.compressedSize)

        case .spool(let temporary):
            return FileRangeStream(
                try RandomAccessFile(temporary.url, shownAs: nil),
                offset: 0,
                length: record.compressedSize
            )

        case .nowhere:
            return DataStream(Data())
        }
    }

    /// A member under the old ZIP encryption, decrypted with `password`; throws `wrongPassword`
    /// when the password does not fit.
    ///
    /// The old encryption proves a password with one byte, so one wrong password in 256 gets past
    /// `check`. For a compressed member there is a second look: the start of what it decrypts to
    /// must be compressed data. What is not is a wrong password (asked for again, and not kept),
    /// not a damaged archive, which is what the user was told once in every 256 wrong answers.
    private static func classicDecrypted(
        _ record: ZipRecord,
        method: UInt16,
        password: String,
        check: UInt8,
        name: String
    ) throws -> any ByteStream {
        let opened = try ZipDecryptStream(try raw(record), password: password, check: check, name: name)
        if method == ZipRecord.methodDeflate, record.compressedSize > 0 {
            try probe(record, password: password, check: check, name: name)
        }
        return opened
    }

    /// Throws `wrongPassword` when the start of what a compressed member decrypts to with
    /// `password` is not compressed data.
    private static func probe(_ record: ZipRecord, password: String, check: UInt8, name: String) throws {
        let inflated = InflateStream(
            try ZipDecryptStream(try raw(record), password: password, check: check, name: name),
            wrapping: .raw,
            control: nil
        )
        defer { inflated.close() }
        // As much as the member holds, up to 4 KB and a byte, so that a shorter one is seen to
        // end where it should: what a wrong password decrypts to is now and then a short stream
        // of compressed data (it was then a CRC error, and the password was not asked for again).
        let probed = (1 << 12) + 1
        let start: Data
        do {
            start = try inflated.readFully(probed)
        } catch ArchiveError.damaged {
            throw ArchiveError.wrongPassword(name)
        }
        guard UInt64(start.count) == min(record.uncompressedSize, UInt64(probed)) else {
            throw ArchiveError.wrongPassword(name)
        }
    }

    /// The contents of a ZIP member: decrypted (asking for the password when it is needed),
    /// decompressed, and checked against its size and checksum as it is read.
    internal func openZip(_ record: ZipRecord, path: String) throws -> any ByteStream {
        var method = record.method
        var aes: ZipAES.Field?
        if record.method == ZipAES.method {
            guard let field = record.aes else { throw ArchiveError.unsupported("The encryption of \(path)") }
            (aes, method) = (field, field.method)
        }
        guard method == ZipRecord.methodStored || method == ZipRecord.methodDeflate else {
            throw ArchiveError.unsupported("The compression method \(method) of \(path)")
        }
        var stream: any ByteStream
        var used: String?
        if record.isEncrypted {
            (stream, used) = try decrypted(record, method: method, aes: aes)
        } else {
            stream = try Self.raw(record)
        }
        if method == ZipRecord.methodDeflate { stream = InflateStream(stream, wrapping: .raw, control: nil) }
        stream = SizeGuardStream(stream, limit: record.uncompressedSize, name: path)
        // (AE-2 leaves the checksum out: the member's authentication code stands for it.)
        if aes?.version == 2 {
            return stream
        }
        guard let used else {
            return CRCCheckStream(stream, expected: record.crc, name: path, onFailure: nil)
        }
        // One wrong password in 256 passes the check byte; then the data cannot be unpacked,
        // or its checksum is wrong. Such a password is not kept for the next member.
        return CRCCheckStream(stream, expected: record.crc, name: path) { [weak self] in self?.forget(used) }
    }

    /// The decrypted (still compressed) bytes of an encrypted member, and the password that
    /// opened it.
    private func decrypted(_ record: ZipRecord, method: UInt16, aes: ZipAES.Field?) throws -> (any ByteStream, String) {
        // The byte that proves the password: from the CRC, or from the time when the CRC
        // was not known yet as the member was written.
        let check = record.flags & ZipRecord.flagDescriptor != 0 ? UInt8(record.dosTime >> 8) : UInt8(record.crc >> 24)
        let archiveName = name
        return try unlocked { [weak self] password -> (any ByteStream) in
            guard let aes else {
                return try Self.classicDecrypted(
                    record,
                    method: method,
                    password: password,
                    check: check,
                    name: archiveName
                )
            }
            return try ZipAESDecryptStream(
                try Self.raw(record),
                length: record.compressedSize,
                field: aes,
                password: password,
                name: archiveName
            ) {
                self?.forget(password)
            }
        }
    }
}
