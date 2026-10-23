import AFMKernel
import Foundation

/// Compresses the members of a new ZIP on all cores.
///
/// Files are cut into pieces of one megabyte; the pieces of a window (many small files, or parts of
/// a large one) are deflated at the same time and then written in order. Deflate allows that:
/// pieces compressed independently form one valid stream when each but the last ends on a byte
/// boundary. Used by one thread; only the compression itself runs on the others.
internal final class ZipPacker {
    private struct Piece {
        let member: Int
        let data: Data
        let isFirst: Bool
        let isLast: Bool
        let stored: Bool
    }

    /// A piece as it goes into the archive.
    private struct Packed {
        /// The bytes to write: deflated, or the piece as it is.
        let data: Data
        /// The checksum of the piece before compression.
        let crc: UInt32
        /// True when `data` is the piece as it is.
        let stored: Bool
    }

    private struct Member {
        var record: ZipRecord
        let expectedSize: UInt64
        var opened: ZipWriter.OpenMember?
        var crypto: ZipCrypto?
        var aes: ZipAES.Encryptor?
    }

    /// The size of the pieces that are compressed independently, and of the blocks `add` takes.
    internal static let pieceSize = 1 << 20

    /// The writer of the archive; members of an existing archive can be put through it directly.
    internal let writer: ZipWriter
    private let level: Int
    private let password: String?
    private let encryption: ZipEncryption
    private var pieces: [Piece] = []
    private var pendingBytes = 0
    /// The members whose pieces wait in `pieces`, in order; the first is number `firstMember`.
    private var members: [Member] = []
    private var firstMember = 0
    private let windowBytes = ZipPacker.pieceSize * max(2, ProcessInfo.processInfo.activeProcessorCount * 2)

    /// `level` 0 stores without compressing.
    ///
    /// With a password the members are encrypted: with AES-256, or the traditional way when that is
    /// asked for (spec 08 › Encryption; see `ZipEncryption` for what each is worth).
    internal init(
        _ output: OutputFile,
        level: Int,
        password: String?,
        encryption: ZipEncryption,
        limits: ZipLimits
    ) {
        writer = ZipWriter(output, limits: limits)
        self.level = level
        self.password = password?.isEmpty == false ? password : nil
        self.encryption = encryption
    }

    /// Compresses one piece; a piece that is to be stored, or that does not shrink, stays as it is.
    private static func pack(_ piece: Piece, level: Int) -> Result<Packed, any Error> {
        Result {
            let crc = CRC32.of(piece.data)
            if piece.stored || piece.data.isEmpty && piece.isFirst {
                return Packed(data: piece.data, crc: crc, stored: true)
            }
            let deflated = try Deflater.piece(piece.data, level: level, final: piece.isLast, calls: .zlib)
            // A small file that does not shrink is stored as it is.
            if piece.isFirst, piece.isLast, deflated.count >= piece.data.count {
                return Packed(data: piece.data, crc: crc, stored: true)
            }
            return Packed(data: deflated, crc: crc, stored: false)
        }
    }

    /// Adds a member.
    ///
    /// `next` delivers its contents in blocks of at most `pieceSize`, nil at the end; folders and
    /// empty files deliver nothing. The record carries name, time and attributes; sizes, checksum
    /// and method are filled in here. `stored` keeps the contents as they are.
    internal func add(_ record: ZipRecord, expectedSize: UInt64, stored: Bool, next: () throws -> Data?) throws {
        let id = firstMember + members.count
        members.append(Member(record: record, expectedSize: expectedSize))
        let isStored = stored || level == 0
        var current = try next()
        var isFirst = true
        repeat {
            // One block is read ahead, to know which piece is the last.
            let following = current == nil ? nil : try next()
            pieces.append(
                Piece(member: id, data: current ?? Data(), isFirst: isFirst, isLast: following == nil, stored: isStored)
            )
            pendingBytes += current?.count ?? 0
            if pendingBytes >= windowBytes { try drain() }
            isFirst = false
            current = following
        } while current != nil
    }

    /// Compresses the waiting pieces on all cores and writes them in order.
    private func drain() throws {
        let packed = Parallel.map(pieces, serialBelow: 2) { [level] piece in Self.pack(piece, level: level) }
        for (piece, outcome) in zip(pieces, packed) {
            var member = members[piece.member - firstMember]
            try write(piece, try outcome.get(), of: &member)
            members[piece.member - firstMember] = member
        }
        // Every member whose last piece was written is done; one whose pieces go on stays.
        let done = pieces.lazy.filter(\.isLast).count
        members.removeFirst(done)
        firstMember += done
        pieces.removeAll(keepingCapacity: true)
        pendingBytes = 0
    }

    /// Writes one piece of `member`: the first begins the member, the last ends it.
    private func write(_ piece: Piece, _ packed: Packed, of member: inout Member) throws {
        if piece.isFirst { try begin(&member, stored: packed.stored) }
        let payload = member.aes?.encrypt(packed.data) ?? member.crypto?.encrypt(packed.data) ?? packed.data
        try writer.append(payload)
        member.record.crc = CRC32.combine(member.record.crc, packed.crc, secondLength: piece.data.count)
        member.record.uncompressedSize += UInt64(piece.data.count)
        member.record.compressedSize += UInt64(payload.count)
        if piece.isLast, let aes = member.aes {
            // The code that proves the contents ends the member and stands for its checksum.
            let trailer = aes.trailer()
            try writer.append(trailer)
            member.record.compressedSize += UInt64(trailer.count)
            member.record.crc = 0
        }
        if piece.isLast, let opened = member.opened { try writer.end(opened, member.record, headerChanged: true) }
    }

    /// Begins `member` in the archive: its method, its encryption and its local header.
    private func begin(_ member: inout Member, stored: Bool) throws {
        member.record.method = stored ? ZipRecord.methodStored : ZipRecord.methodDeflate
        var header = Data()
        if let password, !member.record.isDirectory, encryption == .aes256 {
            let aes = try ZipAES.Encryptor(password: password, method: member.record.method)
            member.record.setAES(aes.field)
            header = aes.header
            member.aes = aes
        } else if let password, !member.record.isDirectory {
            // The checksum is not known yet, so the password check byte comes from the
            // time and the final values follow the data (general purpose bit 3).
            member.record.flags |= ZipRecord.flagEncrypted | ZipRecord.flagDescriptor
            var crypto = ZipCrypto(password: password)
            header = crypto.header(check: UInt8(member.record.dosTime >> 8))
            member.crypto = crypto
        }
        member.opened = try writer.begin(
            member.record,
            localExtra: nil,
            expectedSize: member.expectedSize + UInt64(header.count)
        )
        try writer.append(header)
        member.record.compressedSize = UInt64(header.count)
    }

    /// Writes what still waits, then the archive's directory with `comment`.
    internal func finish(comment: Data) throws {
        try drain()
        try writer.finish(comment: comment)
    }

    deinit {
        // Nothing to release.
    }
}
