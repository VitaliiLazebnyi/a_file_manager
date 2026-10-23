import AFMKernel
import Foundation

/// The writer of a new member.
extension OpenArchive {
    /// Writes one new member of a ZIP: compresses into a temporary file as the data arrives.
    ///
    /// The data is cut into pieces of one megabyte, and the pieces that have gathered are compressed on
    /// all cores at once (see `ZipPacker` for why that gives one valid stream). With a password the
    /// compressed bytes are encrypted (AES-256) as they are written. Used by the one thread that copies
    /// the file.
    ///
    /// Unchecked: used by one thread at a time, as `FileWriter` allows; `interrupt` touches only
    /// `interruption`, which is safe from any thread.
    internal final class ZipMemberWriter: FileWriter, @unchecked Sendable {
        private let archive: OpenArchive
        private let path: String
        private let temporary: TemporaryFile
        private let output: OutputFile
        private let level: Int
        private let room: SpaceWatch
        private let encryptor: ZipAES.Encryptor?
        private var buffer = Data()
        private var crc: UInt32 = 0
        private var size: UInt64 = 0
        /// True until the writer has started: one that fails to start is given up by whoever made
        /// it, which hears of the failure and takes its count back.
        private var isClosed = true
        /// Set by `interrupt()`, from any thread.
        private let interruption = StreamInterrupt()
        private let window = ZipPacker.pieceSize * max(2, ProcessInfo.processInfo.activeProcessorCount)

        /// Starts a member at `path` of `archive`, compressed at `level` (0 stores) into the
        /// temporary file `spool`, whose folder's room `room` watches; encrypted with a `password`.
        internal init(
            archive: OpenArchive,
            path: String,
            level: Int,
            password: String?,
            spool: URL,
            room: SpaceWatch
        ) throws {
            self.archive = archive
            self.path = path
            self.level = level
            self.room = room
            encryptor = try password.map { given in
                try ZipAES.Encryptor(
                    password: given,
                    method: level > 0 ? ZipRecord.methodDeflate : ZipRecord.methodStored
                )
            }
            output = try OutputFile(creating: spool, mode: 0o600)
            temporary = TemporaryFile(spool)
            if let encryptor { try output.write(encryptor.header) }
            isClosed = false
        }

        /// Makes the next write fail; may be called from any thread.
        internal func interrupt() {
            interruption.set()
        }

        private func put(_ data: Data) throws {
            try output.write(encryptor?.encrypt(data) ?? data)
        }

        /// Takes the next bytes of the member; fails when the room for them is not there.
        internal func write(_ data: Data) throws {
            try interruption.check()
            guard room.allows(UInt64(data.count)) else { throw ArchiveError.noRoom(archive.name) }
            size += UInt64(data.count)
            guard level > 0 else {
                crc = CRC32.update(crc, data)
                try put(data)
                return
            }
            buffer.append(data)
            if buffer.count >= window { try drain(final: false) }
        }

        /// Compresses the whole pieces that have gathered; at the end also what is left.
        private func drain(final: Bool) throws {
            var pieces: [Data] = []
            var offset = buffer.startIndex
            while buffer.endIndex - offset >= ZipPacker.pieceSize || (final && offset < buffer.endIndex) {
                let end = min(offset + ZipPacker.pieceSize, buffer.endIndex)
                pieces.append(buffer.subdata(in: offset..<end))
                offset = end
            }
            buffer = Data(buffer[offset...])
            // The stream needs a piece that ends it, even an empty one.
            if final, pieces.isEmpty { pieces = [Data()] }
            let (pieceLevel, last) = (level, pieces.count - 1)
            let packed = Parallel.map(Array(pieces.enumerated())) { index, piece in
                Result {
                    (
                        data: try Deflater.piece(piece, level: pieceLevel, final: final && index == last, calls: .zlib),
                        crc: CRC32.of(piece)
                    )
                }
            }
            for (piece, outcome) in zip(pieces, packed) {
                let result = try outcome.get()
                try interruption.check()
                crc = CRC32.combine(crc, result.crc, secondLength: piece.count)
                try put(result.data)
            }
        }

        /// Ends the member: it joins the archive's directory with the date and permissions
        /// given (now and `0o644` when none are), or fails, and then nothing joins.
        internal func close(attributes: FileAttributes) throws {
            guard !isClosed else {
                return
            }
            isClosed = true
            do {
                try interruption.check()
                // An encrypted member says how it was compressed before its size is known, so
                // an empty one is a (valid, empty) compressed stream too.
                if level > 0, size > 0 || encryptor != nil { try drain(final: true) }
                if let encryptor { try output.write(encryptor.trailer()) }
                try output.close(durably: false)
            } catch {
                try? archive.finishWrite(nil, path: path)
                throw error
            }
            var record = ZipRecord.new(
                name: path,
                isDirectory: false,
                modified: attributes.modified ?? Date(),
                permissions: attributes.permissions ?? 0o644,
                isSymbolicLink: false
            )
            record.crc = crc
            record.uncompressedSize = size
            record.compressedSize = output.position
            record.method = level > 0 && size > 0 ? ZipRecord.methodDeflate : ZipRecord.methodStored
            record.source = output.position > 0 ? .spool(temporary) : .nowhere
            if let encryptor { record.setAES(encryptor.field) }
            try archive.finishWrite(record, path: path)
        }

        deinit {
            if !isClosed { try? archive.finishWrite(nil, path: path) }
        }
    }
}
