import Foundation

/// One member of a TAR archive as its header describes it (ustar, with the pax and GNU
/// extensions for long names and large sizes).
struct TarHeader {
    enum Kind: Equatable {
        case file, directory, symbolicLink, hardLink
        /// Devices, pipes and other things a file panel does not show.
        case other
    }

    var path: String
    var kind: Kind = .file
    var size: UInt64 = 0
    var modified = Date(timeIntervalSince1970: 0)
    var permissions: UInt16 = 0o644
    var linkTarget = ""
    /// A file with holes as GNU tar stores it: its data is a list of pieces, not the file's
    /// contents. Such members are shown but not read.
    var isSparse = false
    /// The size of a sparse file once its holes are restored, when the header says it.
    var realSize: UInt64?
    /// (Old GNU sparse format.) More blocks describing the pieces follow the header.
    var hasSparseExtension = false

    static let blockSize = 512
    /// Sizes beyond this are not sizes of anything: a header that claims more is damaged.
    static let maxSize = UInt64(Int64.max)

    /// Whether a block looks like a TAR header: its checksum fits.
    static func looksLikeHeader(_ block: Data) -> Bool {
        guard block.count >= blockSize else { return false }
        return isHeader([UInt8](block.prefix(blockSize)))
    }

    private static func isHeader(_ bytes: [UInt8]) -> Bool {
        guard bytes.contains(where: { $0 != 0 }), let stored = octal(bytes[148..<156]) else { return false }
        return checksum(bytes) == stored
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt64 {
        var sum: UInt64 = 0
        for (index, byte) in bytes.enumerated() { sum += (148..<156).contains(index) ? 32 : UInt64(byte) }
        return sum
    }

    private static func octal(_ field: ArraySlice<UInt8>) -> UInt64? {
        // GNU tar writes large numbers in binary, marked by the top bit of the first byte.
        if let first = field.first, first & 0x80 != 0 {
            return field.dropFirst().reduce(UInt64(first & 0x7F)) { ($0 << 8) | UInt64($1) }
        }
        let digits = field.filter { $0 != 0 && $0 != 32 }
        guard digits.allSatisfy({ (48...55).contains($0) }) else { return nil }
        return digits.reduce(UInt64(0)) { ($0 << 3) | UInt64($1 - 48) }
    }

    private static func text(_ field: ArraySlice<UInt8>) -> String {
        let bytes = field.prefix { $0 != 0 }
        return String(bytes: bytes, encoding: .utf8) ?? String(decoding: bytes, as: Unicode.ASCII.self)
    }

    /// The fixed fields of a header block; nil for a block that is not one. `typeFlag` is the
    /// raw type, which the reader needs for the extension records.
    static func parse(_ block: Data) -> (header: TarHeader, typeFlag: UInt8)? {
        guard block.count >= blockSize else { return nil }
        // The block is copied once, for the check and for the fields.
        let bytes = [UInt8](block.prefix(blockSize))
        guard isHeader(bytes) else { return nil }
        var name = text(bytes[0..<100])
        // Only the POSIX format ("ustar" and a zero byte) has a path prefix there. Old GNU
        // headers ("ustar" and two spaces) keep access and change times in the same bytes.
        if Array(bytes[257..<263]) == [117, 115, 116, 97, 114, 0] {
            let prefix = text(bytes[345..<500])
            if !prefix.isEmpty { name = prefix + "/" + name }
        }
        let typeFlag = bytes[156]
        var header = TarHeader(path: name)
        switch typeFlag {
        case 0, 48, 55: header.kind = name.hasSuffix("/") ? .directory : .file
        case 83:
            header.kind = .file
            header.isSparse = true
            header.realSize = octal(bytes[483..<495])
            header.hasSparseExtension = bytes[482] != 0
        case 49: header.kind = .hardLink
        case 50: header.kind = .symbolicLink
        case 53: header.kind = .directory
        default: header.kind = .other
        }
        header.size = octal(bytes[124..<136]) ?? 0
        header.modified = date(TimeInterval(octal(bytes[136..<148]) ?? 0))
        // Without the bits that make a program run as its owner or group (see ZipRecord.permissions).
        header.permissions = UInt16((octal(bytes[100..<108]) ?? 0o644) & 0o1777)
        header.linkTarget = text(bytes[157..<257])
        return (header, typeFlag)
    }

    /// A time as a date; times no calendar can show (a header may hold any number) are cut
    /// to the years 0 to 9999.
    static func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds.isFinite ? max(-62_167_219_200, min(seconds, 253_402_300_799)) : 0)
    }

    /// The records of a pax extended header: `<length> <key>=<value>\n`. The length counts
    /// the whole record, its own digits included; a record that says less ends the list.
    static func paxRecords(_ data: Data) -> [String: String] {
        var records: [String: String] = [:]
        var rest = data[...]
        while let space = rest.firstIndex(of: 32), space - rest.startIndex <= 20,
              let length = Int(String(decoding: rest[..<space], as: UTF8.self)), length > space - rest.startIndex + 1, rest.count >= length {
            let record = rest[rest.index(after: space)..<(rest.startIndex + length)]
            if let equals = record.firstIndex(of: 61) {
                let value = record[record.index(after: equals)...].dropLast()
                records[String(decoding: record[..<equals], as: UTF8.self)] = String(decoding: value, as: UTF8.self)
            }
            rest = rest[(rest.startIndex + length)...]
        }
        return records
    }

    // MARK: Writing

    private static func put(_ text: String, into block: inout [UInt8], at offset: Int, length: Int) {
        for (index, byte) in text.utf8.prefix(length).enumerated() { block[offset + index] = byte }
    }

    private static func putOctal(_ value: UInt64, into block: inout [UInt8], at offset: Int, length: Int) {
        let digits = String(value, radix: 8)
        let padded = String(repeating: "0", count: max(0, length - 1 - digits.count)) + digits
        put(String(padded.suffix(length - 1)), into: &block, at: offset, length: length - 1)
    }

    private static func block(name: String, prefix: String = "", typeFlag: UInt8, size: UInt64, modified: Date, permissions: UInt16,
                              linkTarget: String = "") -> Data {
        var block = [UInt8](repeating: 0, count: blockSize)
        put(name, into: &block, at: 0, length: 100)
        putOctal(UInt64(permissions), into: &block, at: 100, length: 8)
        // Owner 0/0 with empty names, as archives made for exchange usually carry (spec 08 › Layout of the archives produced).
        putOctal(0, into: &block, at: 108, length: 8)
        putOctal(0, into: &block, at: 116, length: 8)
        putOctal(min(size, 0o77777777777), into: &block, at: 124, length: 12)
        putOctal(UInt64(max(0, modified.timeIntervalSince1970)), into: &block, at: 136, length: 12)
        block[156] = typeFlag
        put(linkTarget, into: &block, at: 157, length: 100)
        put("ustar", into: &block, at: 257, length: 5)
        put("00", into: &block, at: 263, length: 2)
        put(prefix, into: &block, at: 345, length: 155)
        let sum = String(checksum(block), radix: 8)
        put(String(repeating: "0", count: max(0, 6 - sum.count)) + sum, into: &block, at: 148, length: 6)
        block[154] = 0
        block[155] = 32
        return Data(block)
    }

    /// The header blocks for this member: one ustar header, preceded by a pax record when the
    /// name, the link or the size does not fit the fixed fields.
    func encoded() -> Data {
        let storedPath = kind == .directory && !path.hasSuffix("/") ? path + "/" : path
        var extended: [(String, String)] = []
        var (name, prefix) = (storedPath, "")
        if storedPath.utf8.count > 100 {
            // ustar splits a long path at a slash into prefix (155) and name (100).
            let bytes = Array(storedPath.utf8)
            let split = bytes.indices.last { bytes[$0] == 47 && $0 <= 155 && bytes.count - $0 - 1 <= 100 && $0 > 0 && $0 < bytes.count - 1 }
            if let split, let head = String(bytes: bytes[..<split], encoding: .utf8), let tail = String(bytes: bytes[(split + 1)...], encoding: .utf8) {
                (name, prefix) = (tail, head)
            } else {
                extended.append(("path", storedPath))
                name = String(decoding: bytes.suffix(100), as: UTF8.self)
            }
        }
        if linkTarget.utf8.count > 100 { extended.append(("linkpath", linkTarget)) }
        if size > 0o77777777777 { extended.append(("size", String(size))) }
        var data = Data()
        if !extended.isEmpty {
            var records = Data()
            for (key, value) in extended {
                // The length counts itself, so it is found by trying.
                let body = " \(key)=\(value)\n"
                var length = body.utf8.count + 1
                while String(length).utf8.count + body.utf8.count != length { length = String(length).utf8.count + body.utf8.count }
                records.append(Data("\(length)\(body)".utf8))
            }
            data.append(TarHeader.block(name: "PaxHeader/" + String(name.suffix(80)), typeFlag: 120, size: UInt64(records.count),
                                        modified: modified, permissions: 0o644))
            data.append(records)
            data.append(TarHeader.padding(after: UInt64(records.count)))
        }
        let typeFlag: UInt8 = kind == .directory ? 53 : kind == .symbolicLink ? 50 : kind == .hardLink ? 49 : 48
        data.append(TarHeader.block(name: name, prefix: prefix, typeFlag: typeFlag, size: kind == .file ? size : 0, modified: modified,
                                    permissions: permissions, linkTarget: linkTarget))
        return data
    }

    /// The zero bytes that fill a member's data up to a whole block.
    static func padding(after size: UInt64) -> Data {
        Data(count: Int((UInt64(blockSize) - size % UInt64(blockSize)) % UInt64(blockSize)))
    }

    /// Two empty blocks end an archive.
    static let endOfArchive = Data(count: 2 * blockSize)
}

/// Reads a TAR archive from a stream, member by member. After `next()` the member's data must
/// be read to its end or skipped before the next call. `position` is where the stream stands,
/// so a caller that reads from a file can note where each member's data lies.
final class TarReader {
    private let stream: ByteStream
    private(set) var position: UInt64 = 0
    private var pendingData: UInt64 = 0
    private var pendingPadding: UInt64 = 0
    /// The request that ends the reads of the stream underneath; it travels with the reader
    /// when this is kept for the next member.
    let control: StreamInterrupt?

    init(_ stream: ByteStream, control: StreamInterrupt? = nil) {
        self.stream = stream
        self.control = control
    }

    private func block() throws -> Data? {
        let data = try stream.readFully(TarHeader.blockSize)
        position += UInt64(data.count)
        if data.isEmpty { return nil }
        guard data.count == TarHeader.blockSize else { throw ArchiveError.damaged("the TAR archive ends in the middle of a header") }
        return data
    }

    private func payload(_ size: UInt64) throws -> Data {
        guard size <= 1 << 24 else { throw ArchiveError.damaged("a TAR extension record is too large") }
        let data = try stream.readFully(Int(size))
        guard data.count == Int(size) else { throw ArchiveError.damaged("the TAR archive ends in the middle of a record") }
        let padding = UInt64(TarHeader.padding(after: size).count)
        try stream.skip(padding)
        position += size + padding
        return data
    }

    /// The next member; nil at the end of the archive.
    func next() throws -> TarHeader? {
        try skipData()
        var longName: String?, longLink: String?
        var pax: [String: String] = [:]
        while true {
            try control?.check()
            guard let data = try block() else { return nil }
            // An empty block ends the archive.
            if data.allSatisfy({ $0 == 0 }) { return nil }
            guard let (parsed, typeFlag) = TarHeader.parse(data) else { throw ArchiveError.damaged("a TAR header has a wrong checksum") }
            var header = parsed
            func text(_ data: Data) -> String { String(decoding: data.prefix { $0 != 0 }, as: UTF8.self) }
            switch typeFlag {
            case 76: longName = text(try payload(header.size))             // GNU long name
            case 75: longLink = text(try payload(header.size))             // GNU long link
            case 120: pax.merge(TarHeader.paxRecords(try payload(header.size))) { _, new in new }
            case 103: _ = try payload(header.size)                         // pax global header
            default:
                if let longName { header.path = longName }
                if let longLink { header.linkTarget = longLink }
                if let path = pax["path"] { header.path = path }
                if let link = pax["linkpath"] { header.linkTarget = link }
                if let size = pax["size"].flatMap(UInt64.init) { header.size = size }
                if let time = pax["mtime"].flatMap(Double.init) { header.modified = TarHeader.date(time) }
                if pax.keys.contains(where: { $0.hasPrefix("GNU.sparse.") }) {
                    header.isSparse = true
                    if let name = pax["GNU.sparse.name"] { header.path = name }
                    header.realSize = (pax["GNU.sparse.realsize"] ?? pax["GNU.sparse.size"]).flatMap(UInt64.init) ?? header.realSize
                }
                guard header.size <= TarHeader.maxSize else { throw ArchiveError.damaged("a TAR header gives an impossible size") }
                // The list of pieces of an old-style sparse file goes on in further blocks.
                var extended = header.hasSparseExtension
                while extended {
                    guard let more = try block() else { throw ArchiveError.damaged("the TAR archive ends in the middle of a header") }
                    extended = more[more.startIndex + 504] != 0
                }
                if header.kind == .file, header.path.hasSuffix("/") { header.kind = .directory }
                // Only files carry data; a size on anything else is not followed by blocks.
                pendingData = header.kind == .file || header.kind == .other ? header.size : 0
                if header.kind == .hardLink || header.kind == .symbolicLink || header.kind == .directory { pendingData = 0 }
                pendingPadding = UInt64(TarHeader.padding(after: pendingData).count)
                return header
            }
        }
    }

    /// The next block of the current member's data; nil at its end.
    func readData(upToCount count: Int) throws -> Data? {
        guard pendingData > 0 else { return nil }
        guard let data = try stream.read(upToCount: Int(min(UInt64(count), pendingData))) else {
            throw ArchiveError.damaged("the TAR archive ends in the middle of a file")
        }
        pendingData -= UInt64(data.count)
        position += UInt64(data.count)
        return data
    }

    func skipData() throws {
        // Both are bounded when they are set (`maxSize`, one block), so the sum fits.
        let count = pendingData.plusClamped(pendingPadding)
        guard count > 0 else { return }
        try stream.skip(count)
        position += count
        (pendingData, pendingPadding) = (0, 0)
    }

    func close() {
        stream.close()
    }
}

/// The data of the member a `TarReader` stands on, as a stream.
final class TarMemberStream: ByteStream {
    private let reader: TarReader
    private let closesReader: Bool
    private var onClose: ((Bool) -> Void)?
    private var failed = false

    /// With `closesReader: false` the reader goes on to the next member afterwards; `onClose`
    /// is then told, once, that the reader is free again, and whether it can still be used
    /// (it cannot after an error).
    init(_ reader: TarReader, closesReader: Bool = true, onClose: ((Bool) -> Void)? = nil) {
        self.reader = reader
        self.closesReader = closesReader
        self.onClose = onClose
    }

    func read(upToCount count: Int) throws -> Data? {
        do {
            return try reader.readData(upToCount: count)
        } catch {
            failed = true
            throw error
        }
    }

    func close() {
        if closesReader { reader.close() }
        onClose?(!failed)
        onClose = nil
    }
}
