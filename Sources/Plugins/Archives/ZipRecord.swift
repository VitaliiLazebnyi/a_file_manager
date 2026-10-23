import Foundation

/// What the central directory says about a member, kept completely so that a member can be
/// written into a new archive without touching its compressed data.
internal struct ZipRecord {
    /// The parts of an entry that can change after it was written.
    internal struct Changes: OptionSet {
        /// The name: it also stands in front of the member's data, which therefore moves.
        internal static let name = Self(rawValue: 1)
        /// The time: also in the header in front of the data, where it is corrected in place.
        internal static let time = Self(rawValue: 2)
        /// What only the directory holds.
        internal static let attributes = Self(rawValue: 4)
        /// Not a change: the member came through a writer and has not been renamed since.
        ///
        /// A job that copies a file in writes it under a temporary name first; such a member is
        /// still on its way.
        internal static let arriving = Self(rawValue: 8)

        /// The bits of the set.
        internal let rawValue: UInt8
    }

    /// "Made by": Unix (3), version 3.0 of the format.
    internal static let madeByUnix: UInt16 = 3 << 8 | 30
    /// The flag of an encrypted member.
    internal static let flagEncrypted: UInt16 = 1
    /// The flag of a member whose sizes and checksum follow its data in a descriptor.
    internal static let flagDescriptor: UInt16 = 1 << 3
    /// The flag of a name in UTF-8.
    internal static let flagUTF8: UInt16 = 1 << 11
    /// The method of a member stored without compression.
    internal static let methodStored: UInt16 = 0
    /// The method of a member compressed with Deflate.
    internal static let methodDeflate: UInt16 = 8

    /// The system and format version that wrote the member; the system decides what the external
    /// attributes mean.
    internal var versionMadeBy: UInt16 = Self.madeByUnix
    /// The general purpose flags (`flagEncrypted`, `flagDescriptor`, `flagUTF8`).
    internal var flags: UInt16 = 0
    /// How the data is compressed (`methodStored`, `methodDeflate`, `ZipAES.method`, ...).
    internal var method: UInt16 = 0
    /// The DOS time of the last change (see `DOSTime`).
    internal var dosTime: UInt16 = 0
    /// The DOS date of the last change (see `DOSTime`).
    internal var dosDate: UInt16 = 0x21
    /// The CRC-32 of the contents; 0 for AE-2 members.
    internal var crc: UInt32 = 0
    /// The size of the stored data in bytes.
    internal var compressedSize: UInt64 = 0
    /// The size of the contents in bytes.
    internal var uncompressedSize: UInt64 = 0
    // Name, extra fields and comment are kept in the smallest form that holds them: an
    // archive of millions of members keeps a record for each. The name is text when it is
    // valid UTF-8 (a short one then needs no memory of its own, and a long one shares it
    // with the path of the entry it belongs to), and bytes otherwise.
    private var nameText = ""
    private var nameRaw: [UInt8] = []
    private var extraStore: [UInt8] = []
    private var commentStore: [UInt8] = []

    /// The name as the archive writes it.
    internal var nameBytes: Data {
        get { nameRaw.isEmpty ? Data(nameText.utf8) : Data(nameRaw) }
        set {
            if var text = String(data: newValue, encoding: .utf8), text.utf8.elementsEqual(newValue) {
                text.makeContiguousUTF8()
                (nameText, nameRaw) = (text, [])
            } else {
                (nameText, nameRaw) = ("", [UInt8](newValue))
            }
        }
    }

    /// How many bytes the name has.
    internal var nameLength: Int { !nameRaw.isEmpty ? nameRaw.count : nameText.utf8.count }
    /// How many bytes the extra fields have.
    internal var extraLength: Int { extraStore.count }
    private var lastNameByte: UInt8? { nameRaw.isEmpty ? nameText.utf8.last : nameRaw.last }

    /// The extra fields of the central directory without the ZIP64 field, which is written anew.
    internal var extra: Data {
        get { Data(extraStore) }
        set { extraStore = [UInt8](newValue) }
    }

    /// The member's comment as the archive stores it.
    internal var comment: Data {
        get { Data(commentStore) }
        set { commentStore = [UInt8](newValue) }
    }
    /// The internal attributes (a text file bit), kept as they are.
    internal var internalAttributes: UInt16 = 0
    /// The external attributes: the Unix mode in the upper half, DOS attributes in the lower.
    internal var externalAttributes: UInt32 = 0
    /// Where the compressed data is.
    internal var source = ZipDataSource.nowhere
    /// What was changed here and is not in the archive file yet.
    internal var unwritten: Changes = []

    /// False for a member whose data (or, for a folder, whose header) is not in the archive yet.
    internal var isInArchive: Bool { headerOffset != nil }

    /// Whether the member is encrypted, in either way.
    internal var isEncrypted: Bool { flags & Self.flagEncrypted != 0 }

    /// Where the member's header lies in the archive file; nil while it is not in the archive yet.
    internal var headerOffset: UInt64? {
        if case .archive(let offset, _) = source {
            return offset
        }
        return nil
    }

    /// The member's name.
    ///
    /// Names marked as UTF-8, and names that are valid UTF-8, are read as such; then Info-ZIP's
    /// Unicode field is tried; what is left is the DOS character set (spec 08 › File-name
    /// encoding).
    internal var name: String {
        if nameRaw.isEmpty {
            if flags & Self.flagUTF8 != 0 || nameText.utf8.allSatisfy({ $0 < 0x80 }) {
                return nameText
            }
            if let field = Self.field(0x7075, in: extra), field.count > 5,
                let text = String(data: field.dropFirst(5), encoding: .utf8)
            {
                return text
            }
            return nameText
        }
        let bytes = nameBytes
        if flags & Self.flagUTF8 != 0 || bytes.allSatisfy({ $0 < 0x80 }),
            let text = String(data: bytes, encoding: .utf8)
        {
            return text
        }
        if let field = Self.field(0x7075, in: extra), field.count > 5,
            let text = String(data: field.dropFirst(5), encoding: .utf8)
        {
            return text
        }
        if let text = String(data: bytes, encoding: .utf8) {
            return text
        }
        // Every byte has a character in the DOS set, so the text is always made.
        return [UInt8](bytes)
            .withUnsafeBufferPointer { buffer in
                CFStringCreateWithBytes(
                    nil,
                    buffer.baseAddress,
                    buffer.count,
                    CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue),
                    false
                )
                    as String
            }
    }

    /// The host system that wrote the entry decides what the external attributes mean.
    private var isFromUnix: Bool { versionMadeBy >> 8 == 3 || versionMadeBy >> 8 == 19 }
    private var unixMode: UInt32 { isFromUnix ? externalAttributes >> 16 : 0 }

    /// Whether the member is a folder: by a name that ends in a slash, or by its attributes.
    internal var isDirectory: Bool {
        lastNameByte == 0x2F || lastNameByte == 0x5C || unixMode & 0o170000 == 0o040000
            || (!isFromUnix && externalAttributes & 0x10 != 0)
    }

    /// Whether the member is a symbolic link, whose data is the link's target.
    internal var isSymbolicLink: Bool { unixMode & 0o170000 == 0o120000 }

    /// A device, a pipe or a socket (see `FileItem.isSpecial`).
    internal var isSpecial: Bool { [0o010000, 0o020000, 0o060000, 0o140000].contains(unixMode & 0o170000) }

    /// Without the bits that make a program run as its owner or group: what comes out of an
    /// archive must not gain rights that way.
    internal var permissions: UInt16 {
        if unixMode & 0o7777 != 0 {
            return UInt16(unixMode & 0o1777)
        }
        // DOS attributes know only "read-only".
        let writable: UInt16 = externalAttributes & 1 != 0 ? 0 : 0o200
        return isDirectory ? 0o555 | writable : 0o444 | writable
    }

    /// The time of the last change.
    internal var modified: Date {
        // The Unix time of the "extended timestamp" field is exact and has no time zone.
        guard let field = Self.field(0x5455, in: extra), field.count >= 5, field[field.startIndex] & 1 != 0 else {
            return DOSTime.date(time: dosTime, date: dosDate)
        }
        var reader = ByteReader(Data(field.dropFirst()))
        return Date(timeIntervalSince1970: TimeInterval(Int32(bitPattern: reader.u32())))
    }

    /// True when the password check byte of this member was taken from its DOS time: it is
    /// encrypted and was written before its checksum was known.
    internal var checksPasswordByTime: Bool { isEncrypted && flags & Self.flagDescriptor != 0 }

    /// A new member as this program writes it: Unix attributes, UTF-8 name, exact time.
    internal static func new(
        name: String,
        isDirectory: Bool,
        modified: Date,
        permissions: UInt16,
        isSymbolicLink: Bool
    )
        -> Self
    {
        var record = Self()
        record.setName(isDirectory && !name.hasSuffix("/") ? name + "/" : name)
        let type: UInt32 = isSymbolicLink ? 0o120000 : isDirectory ? 0o040000 : 0o100000
        record.externalAttributes = (type | UInt32(permissions & 0o7777)) << 16 | (isDirectory ? 0x10 : 0)
        record.setModified(modified)
        return record
    }

    // MARK: Extra fields

    /// The data of the extra field with this id.
    internal static func field(_ id: UInt16, in extra: Data) -> Data? {
        var reader = ByteReader(extra)
        while reader.remaining >= 4 {
            let (fieldID, size) = (reader.u16(), Int(reader.u16()))
            guard size <= reader.remaining else {
                return nil
            }
            let data = reader.bytes(size)
            if fieldID == id {
                return data
            }
        }
        return nil
    }

    /// The extra fields that fit into `room` bytes, whole fields only, in their order.
    ///
    /// Extra data is optional: an entry whose fields grew past what a header can hold loses the
    /// last ones instead of becoming unwritable.
    internal static func fitting(_ extra: Data, into room: Int) -> Data {
        guard extra.count > room else {
            return extra
        }
        var reader = ByteReader(extra)
        var kept = Data()
        while reader.remaining >= 4 {
            let (fieldID, size) = (reader.u16(), Int(reader.u16()))
            guard size <= reader.remaining else { break }
            let data = reader.bytes(size)
            guard kept.count + 4 + size <= room else { continue }
            kept.appendLE(fieldID)
            kept.appendLE(UInt16(size))
            kept.append(data)
        }
        return kept
    }

    /// The extra fields without the one with this id.
    internal static func removing(_ id: UInt16, from extra: Data) -> Data {
        // Most entries do not have the field: then the data is handed back as it is.
        var scan = ByteReader(extra)
        var found = false
        while scan.remaining >= 4, !found {
            let (fieldID, size) = (scan.u16(), Int(scan.u16()))
            guard size <= scan.remaining else {
                found = true
                break
            }
            scan.position += size
            found = fieldID == id
        }
        if !found, scan.remaining == 0 {
            return extra
        }
        var reader = ByteReader(extra)
        var kept = Data()
        while reader.remaining >= 4 {
            let (fieldID, size) = (reader.u16(), Int(reader.u16()))
            guard size <= reader.remaining else { break }
            let data = reader.bytes(size)
            guard fieldID != id else { continue }
            kept.appendLE(fieldID)
            kept.appendLE(UInt16(size))
            kept.append(data)
        }
        return kept
    }

    /// Sets the time of the last change, in the DOS fields and the exact time field.
    internal mutating func setModified(_ date: Date) {
        // The DOS time of such a member is part of its encryption: changing it would make the
        // right password look wrong. The exact time field is free to change, and readers
        // prefer it.
        if !checksPasswordByTime { (dosTime, dosDate) = DOSTime.encode(date) }
        let seconds = date.timeIntervalSince1970
        let clamped = seconds.isFinite ? max(Double(Int32.min), min(seconds.rounded(.down), Double(Int32.max))) : 0
        var field = Data([1])
        field.appendLE(UInt32(bitPattern: Int32(clamped)))
        // The field is nine bytes; other fields make way when the 64 KB of an entry are full.
        extra = Self.fitting(Self.removing(0x5455, from: extra), into: 0xFFFF - 9)
        extra.appendLE(UInt16(0x5455))
        extra.appendLE(UInt16(field.count))
        extra.append(field)
        unwritten.insert(.time)
    }

    /// Sets the Unix permission bits; the attributes then say that the member is from Unix.
    internal mutating func setPermissions(_ permissions: UInt16) {
        let type: UInt32 = isSymbolicLink ? 0o120000 : isDirectory ? 0o040000 : 0o100000
        versionMadeBy = Self.madeByUnix
        externalAttributes = (type | UInt32(permissions & 0o7777)) << 16 | (isDirectory ? 0x10 : 0)
        unwritten.insert(.attributes)
    }

    /// Renames the member; the UTF-8 flag follows the new name.
    internal mutating func setName(_ name: String) {
        (nameText, nameRaw) = (name, [])
        nameText.makeContiguousUTF8()
        if nameText.utf8.contains(where: { $0 >= 0x80 }) {
            flags |= Self.flagUTF8
        } else {
            flags &= ~Self.flagUTF8
        }
        // The Unicode name field would contradict the new name.
        extra = Self.removing(0x7075, from: extra)
        unwritten.insert(.name)
    }

    /// Whether everything a header holds is the same in both records.
    internal func hasSameHeader(as other: Self) -> Bool {
        nameText.utf8.elementsEqual(other.nameText.utf8) && nameRaw == other.nameRaw && dosTime == other.dosTime
            && dosDate == other.dosDate
            && extraStore == other.extraStore
            && externalAttributes == other.externalAttributes && versionMadeBy == other.versionMadeBy
            && flags == other.flags
    }
}
