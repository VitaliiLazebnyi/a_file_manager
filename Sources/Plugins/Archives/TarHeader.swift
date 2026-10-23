import Foundation

/// One member of a TAR archive as its header describes it (ustar, with the pax and GNU
/// extensions for long names and large sizes).
internal struct TarHeader {
    /// What a member is, from the type flag of its header.
    internal enum Kind: Equatable {
        /// A folder: a type flag of its own, or a file whose name ends in a slash.
        case directory
        /// Plain data.
        case file
        /// Another name of a member that came earlier in the archive.
        case hardLink
        /// Devices, pipes and other things a file panel does not show.
        case other
        /// A link to the path in `linkTarget`.
        case symbolicLink
    }

    /// The size of a header block and the unit the data of every member is padded to.
    internal static let blockSize = 512
    /// Sizes beyond this are not sizes of anything: a header that claims more is damaged.
    internal static let maxSize = UInt64(Int64.max)

    /// Two empty blocks end an archive.
    internal static let endOfArchive = Data(count: 2 * blockSize)

    /// The member's path inside the archive; a folder's may end in a slash.
    internal var path: String
    /// What the member is.
    internal var kind: Kind = .file
    /// The size of the member's data in bytes (for a sparse file: the size of its list of pieces).
    internal var size: UInt64 = 0
    /// The time of the last change.
    internal var modified = Date(timeIntervalSince1970: 0)
    /// The Unix permission bits, without set-user and set-group ID.
    internal var permissions: UInt16 = 0o644
    /// What a link points to; empty for anything else.
    internal var linkTarget = ""
    /// A file with holes as GNU tar stores it: its data is a list of pieces, not the file's
    /// contents.
    ///
    /// Such members are shown but not read.
    internal var isSparse = false
    /// The size of a sparse file once its holes are restored, when the header says it.
    internal var realSize: UInt64?
    /// (Old GNU sparse format.)
    ///
    /// More blocks describing the pieces follow the header.
    internal var hasSparseExtension = false

    /// Whether a block looks like a TAR header: its checksum fits.
    internal static func looksLikeHeader(_ block: Data) -> Bool {
        guard block.count >= blockSize else {
            return false
        }
        return isHeader([UInt8](block.prefix(blockSize)))
    }

    private static func isHeader(_ bytes: [UInt8]) -> Bool {
        guard bytes.contains(where: { $0 != 0 }), let stored = octal(bytes[148..<156]) else {
            return false
        }
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
        guard digits.allSatisfy({ (48...55).contains($0) }) else {
            return nil
        }
        return digits.reduce(UInt64(0)) { ($0 << 3) | UInt64($1 - 48) }
    }

    /// Text from an archive: UTF-8 when the bytes are valid UTF-8, else the ASCII characters with
    /// a replacement character for every other byte.
    internal static func string(_ bytes: some Collection<UInt8>) -> String {
        String(bytes: bytes, encoding: .utf8) ?? String(decoding: bytes, as: Unicode.ASCII.self)
    }

    private static func text(_ field: ArraySlice<UInt8>) -> String {
        string(field.prefix { $0 != 0 })
    }

    /// The fixed fields of a header block; nil for a block that is not one. `typeFlag` is the
    /// raw type, which the reader needs for the extension records.
    internal static func parse(_ block: Data) -> (header: Self, typeFlag: UInt8)? {
        guard block.count >= blockSize else {
            return nil
        }
        // The block is copied once, for the check and for the fields.
        let bytes = [UInt8](block.prefix(blockSize))
        guard isHeader(bytes) else {
            return nil
        }
        var name = text(bytes[0..<100])
        // Only the POSIX format ("ustar" and a zero byte) has a path prefix there. Old GNU
        // headers ("ustar" and two spaces) keep access and change times in the same bytes.
        if Array(bytes[257..<263]) == [117, 115, 116, 97, 114, 0] {
            let prefix = text(bytes[345..<500])
            if !prefix.isEmpty { name = prefix + "/" + name }
        }
        let typeFlag = bytes[156]
        var header = Self(path: name)
        switch typeFlag {
        case 0, 48, 55:
            header.kind = name.hasSuffix("/") ? .directory : .file

        case 83:
            header.kind = .file
            header.isSparse = true
            header.realSize = octal(bytes[483..<495])
            header.hasSparseExtension = bytes[482] != 0

        case 49:
            header.kind = .hardLink

        case 50:
            header.kind = .symbolicLink

        case 53:
            header.kind = .directory

        default:
            header.kind = .other
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
    internal static func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds.isFinite ? max(-62_167_219_200, min(seconds, 253_402_300_799)) : 0)
    }

    /// The records of a pax extended header: `<length> <key>=<value>\n`.
    ///
    /// The length counts the whole record, its own digits included; a record that says less ends
    /// the list.
    internal static func paxRecords(_ data: Data) -> [String: String] {
        var records: [String: String] = [:]
        var rest = data
        while let space = rest.firstIndex(of: 32), space - rest.startIndex <= 20,
            let length = String(bytes: rest[..<space], encoding: .utf8).flatMap({ Int($0) }),
            length > space - rest.startIndex + 1,
            rest.count >= length
        {
            let record = rest[rest.index(after: space)..<(rest.startIndex + length)]
            if let equals = record.firstIndex(of: 61) {
                let value = record[record.index(after: equals)...].dropLast()
                records[string(record[..<equals])] = string(value)
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

    /// Pax records for the keys and values, each `<length> <key>=<value>\n`.
    private static func encodedRecords(_ extended: [(String, String)]) -> Data {
        var records = Data()
        for (key, value) in extended {
            // The length counts itself, so it is found by trying.
            let body = " \(key)=\(value)\n"
            var length = body.utf8.count + 1
            while String(length).utf8.count + body.utf8.count != length {
                length = String(length).utf8.count + body.utf8.count
            }
            records.append(Data("\(length)\(body)".utf8))
        }
        return records
    }

    /// The zero bytes that fill a member's data up to a whole block.
    internal static func padding(after size: UInt64) -> Data {
        Data(count: Int((UInt64(blockSize) - size % UInt64(blockSize)) % UInt64(blockSize)))
    }

    /// The header blocks for this member: one ustar header, preceded by a pax record when the
    /// name, the link or the size does not fit the fixed fields.
    internal func encoded() -> Data {
        let storedPath = kind == .directory && !path.hasSuffix("/") ? path + "/" : path
        var extended: [(String, String)] = []
        var (name, prefix) = (storedPath, "")
        if storedPath.utf8.count > 100 {
            // ustar splits a long path at a slash into prefix (155) and name (100).
            let bytes = Array(storedPath.utf8)
            let split = bytes.indices.last { index in
                bytes[index] == 47 && index <= 155 && bytes.count - index - 1 <= 100 && index > 0
                    && index < bytes.count - 1
            }
            if let split, let head = String(bytes: bytes[..<split], encoding: .utf8),
                let tail = String(bytes: bytes[(split + 1)...], encoding: .utf8)
            {
                (name, prefix) = (tail, head)
            } else {
                extended.append(("path", storedPath))
                // The end of the path, from the first whole character in its last 100 bytes.
                name = Self.string(bytes.suffix(100).drop { $0 & 0xC0 == 0x80 })
            }
        }
        if linkTarget.utf8.count > 100 { extended.append(("linkpath", linkTarget)) }
        if size > 0o77777777777 { extended.append(("size", String(size))) }
        var data = Data()
        if !extended.isEmpty {
            let records = Self.encodedRecords(extended)
            // The record's own header: the member's time, not its permissions or link.
            let record = Self(path: "PaxHeader/" + String(name.suffix(80)), modified: modified)
            data.append(record.block(name: record.path, prefix: "", typeFlag: 120, size: UInt64(records.count)))
            data.append(records)
            data.append(Self.padding(after: UInt64(records.count)))
        }
        let typeFlag: UInt8 = kind == .directory ? 53 : kind == .symbolicLink ? 50 : kind == .hardLink ? 49 : 48
        data.append(block(name: name, prefix: prefix, typeFlag: typeFlag, size: kind == .file ? size : 0))
        return data
    }

    /// One header block with this member's time, permissions and link target, and the fields given.
    private func block(name: String, prefix: String, typeFlag: UInt8, size: UInt64) -> Data {
        var bytes = [UInt8](repeating: 0, count: Self.blockSize)
        Self.put(name, into: &bytes, at: 0, length: 100)
        Self.putOctal(UInt64(permissions), into: &bytes, at: 100, length: 8)
        // Owner 0/0 with empty names, as archives made for exchange usually carry (spec 08 › Layout
        // of the archives produced).
        Self.putOctal(0, into: &bytes, at: 108, length: 8)
        Self.putOctal(0, into: &bytes, at: 116, length: 8)
        Self.putOctal(min(size, 0o77777777777), into: &bytes, at: 124, length: 12)
        Self.putOctal(UInt64(max(0, modified.timeIntervalSince1970)), into: &bytes, at: 136, length: 12)
        bytes[156] = typeFlag
        Self.put(linkTarget, into: &bytes, at: 157, length: 100)
        Self.put("ustar", into: &bytes, at: 257, length: 5)
        Self.put("00", into: &bytes, at: 263, length: 2)
        Self.put(prefix, into: &bytes, at: 345, length: 155)
        let sum = String(Self.checksum(bytes), radix: 8)
        Self.put(String(repeating: "0", count: max(0, 6 - sum.count)) + sum, into: &bytes, at: 148, length: 6)
        bytes[154] = 0
        bytes[155] = 32
        return Data(bytes)
    }
}
