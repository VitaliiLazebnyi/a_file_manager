import Foundation

/// Reads a TAR archive from a stream, member by member.
///
/// After `next()` the member's data must be read to its end or skipped before the next call.
/// `position` is where the stream stands, so a caller that reads from a file can note where each
/// member's data lies.
internal final class TarReader {
    private let stream: any ByteStream
    /// How many bytes of the stream were read or skipped so far.
    internal private(set) var position: UInt64 = 0
    private var pendingData: UInt64 = 0
    private var pendingPadding: UInt64 = 0
    /// The request that ends the reads of the stream underneath; it travels with the reader
    /// when this is kept for the next member.
    internal let control: StreamInterrupt?

    /// A reader at the start of the archive in `stream`; `control` can end its reads early.
    internal init(_ stream: any ByteStream, control: StreamInterrupt?) {
        self.stream = stream
        self.control = control
    }

    /// The header with what the extension records in front of it say.
    private static func applying(longName: String?, longLink: String?, pax: [String: String], to member: TarHeader)
        throws -> TarHeader
    {
        var header = member
        if let longName { header.path = longName }
        if let longLink { header.linkTarget = longLink }
        if let path = pax["path"] { header.path = path }
        if let link = pax["linkpath"] { header.linkTarget = link }
        if let size = pax["size"].flatMap(UInt64.init) { header.size = size }
        if let time = pax["mtime"].flatMap(Double.init) { header.modified = TarHeader.date(time) }
        if pax.keys.contains(where: { $0.hasPrefix("GNU.sparse.") }) {
            header.isSparse = true
            if let name = pax["GNU.sparse.name"] { header.path = name }
            header.realSize =
                (pax["GNU.sparse.realsize"] ?? pax["GNU.sparse.size"]).flatMap(UInt64.init) ?? header.realSize
        }
        guard header.size <= TarHeader.maxSize else {
            throw ArchiveError.damaged("a TAR header gives an impossible size")
        }
        return header
    }

    /// The text of a GNU long name or link record: up to its first zero byte.
    private static func recordText(_ data: Data) -> String {
        TarHeader.string(data.prefix { $0 != 0 })
    }

    private func block() throws -> Data? {
        let data = try stream.readFully(TarHeader.blockSize)
        position += UInt64(data.count)
        if data.isEmpty {
            return nil
        }
        guard data.count == TarHeader.blockSize else {
            throw ArchiveError.damaged("the TAR archive ends in the middle of a header")
        }
        return data
    }

    private func payload(_ size: UInt64) throws -> Data {
        guard size <= 1 << 24 else { throw ArchiveError.damaged("a TAR extension record is too large") }
        let data = try stream.readFully(Int(size))
        guard data.count == Int(size) else {
            throw ArchiveError.damaged("the TAR archive ends in the middle of a record")
        }
        let padding = UInt64(TarHeader.padding(after: size).count)
        try stream.skip(padding)
        position += size + padding
        return data
    }

    /// The extension records in front of a member, then the member's own header with what they
    /// say; nil at the end of the archive.
    private func memberHeader() throws -> TarHeader? {
        var longName: String?
        var longLink: String?
        var pax: [String: String] = [:]
        var header: TarHeader
        records: while true {
            try control?.check()
            guard let data = try block() else {
                return nil
            }
            // An empty block ends the archive.
            if data.allSatisfy({ $0 == 0 }) {
                return nil
            }
            guard let (parsed, typeFlag) = TarHeader.parse(data) else {
                throw ArchiveError.damaged("a TAR header has a wrong checksum")
            }
            switch typeFlag {
            case 76:
                longName = Self.recordText(try payload(parsed.size))  // GNU long name

            case 75:
                longLink = Self.recordText(try payload(parsed.size))  // GNU long link

            case 120:
                pax.merge(TarHeader.paxRecords(try payload(parsed.size))) { _, new in new }

            case 103:
                _ = try payload(parsed.size)  // pax global header

            default:
                header = parsed
                break records
            }
        }
        return try Self.applying(longName: longName, longLink: longLink, pax: pax, to: header)
    }

    /// The next member; nil at the end of the archive.
    internal func next() throws -> TarHeader? {
        try skipData()
        guard var header = try memberHeader() else {
            return nil
        }
        // The list of pieces of an old-style sparse file goes on in further blocks.
        var extended = header.hasSparseExtension
        while extended {
            guard let more = try block() else {
                throw ArchiveError.damaged("the TAR archive ends in the middle of a header")
            }
            extended = more[more.startIndex + 504] != 0
        }
        if header.kind == .file, header.path.hasSuffix("/") { header.kind = .directory }
        // Only files carry data; a size on anything else is not followed by blocks.
        pendingData = header.kind == .file || header.kind == .other ? header.size : 0
        pendingPadding = UInt64(TarHeader.padding(after: pendingData).count)
        return header
    }

    /// The next block of the current member's data; nil at its end.
    internal func readData(upToCount count: Int) throws -> Data? {
        guard pendingData > 0 else {
            return nil
        }
        guard let data = try stream.read(upToCount: Int(min(UInt64(count), pendingData))) else {
            throw ArchiveError.damaged("the TAR archive ends in the middle of a file")
        }
        pendingData -= UInt64(data.count)
        position += UInt64(data.count)
        return data
    }

    /// Skips what is left of the current member's data and its padding.
    internal func skipData() throws {
        // Both are bounded when they are set (`maxSize`, one block), so the sum fits.
        let count = pendingData.plusClamped(pendingPadding)
        guard count > 0 else {
            return
        }
        try stream.skip(count)
        position += count
        (pendingData, pendingPadding) = (0, 0)
    }

    /// Closes the stream underneath.
    internal func close() {
        stream.close()
    }

    deinit {
        // Nothing to release.
    }
}
