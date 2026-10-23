import CommonCrypto
import Foundation

/// Above these values ZIP needs its 64-bit extension (ZIP64).
///
/// They are parameters so that the rules can be tested without files of four gigabytes.
internal struct ZipLimits: Equatable {
    internal static let standard = Self()

    /// The largest size or offset the classic 32-bit fields may hold.
    internal var maxField: UInt64 = 0xFFFF_FFFE
    /// The largest number of members the classic end record may count.
    internal var maxEntries: Int = 0xFFFE
}

/// Where the compressed bytes of a member are.
internal enum ZipDataSource {
    /// In an archive file, behind the local header at this offset. The record holds on to the
    /// file it was read from: when the archive is rewritten, whoever still has the record
    /// goes on reading the file its offset belongs to.
    case archive(headerOffset: UInt64, file: RandomAccessFile)
    /// In a temporary file, waiting to be written into the archive.
    case spool(TemporaryFile)
    /// Nowhere: folders and empty files.
    case none
}

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

        internal let rawValue: UInt8
    }

    internal static let madeByUnix: UInt16 = 3 << 8 | 30
    internal static let flagEncrypted: UInt16 = 1
    internal static let flagDescriptor: UInt16 = 1 << 3
    internal static let flagUTF8: UInt16 = 1 << 11
    internal static let methodStored: UInt16 = 0
    internal static let methodDeflate: UInt16 = 8

    internal var versionMadeBy: UInt16 = Self.madeByUnix
    internal var flags: UInt16 = 0
    internal var method: UInt16 = 0
    internal var dosTime: UInt16 = 0
    internal var dosDate: UInt16 = 0x21
    internal var crc: UInt32 = 0
    internal var compressedSize: UInt64 = 0
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

    internal var comment: Data {
        get { Data(commentStore) }
        set { commentStore = [UInt8](newValue) }
    }
    internal var internalAttributes: UInt16 = 0
    internal var externalAttributes: UInt32 = 0
    internal var source = ZipDataSource.none
    /// What was changed here and is not in the archive file yet.
    internal var unwritten: Changes = []

    /// False for a member whose data (or, for a folder, whose header) is not in the archive yet.
    internal var isInArchive: Bool { headerOffset != nil }

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
        let nameBytes = self.nameBytes
        if flags & Self.flagUTF8 != 0 || nameBytes.allSatisfy({ $0 < 0x80 }),
            let text = String(data: nameBytes, encoding: .utf8)
        {
            return text
        }
        if let field = Self.field(0x7075, in: extra), field.count > 5,
            let text = String(data: field.dropFirst(5), encoding: .utf8)
        {
            return text
        }
        if let text = String(data: nameBytes, encoding: .utf8) {
            return text
        }
        // Every byte has a character in the DOS set, so the text is always made.
        return [UInt8](nameBytes)
            .withUnsafeBufferPointer {
                CFStringCreateWithBytes(
                    nil,
                    $0.baseAddress,
                    $0.count,
                    CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue),
                    false
                )
                    as String
            }
    }

    /// The host system that wrote the entry decides what the external attributes mean.
    private var isFromUnix: Bool { versionMadeBy >> 8 == 3 || versionMadeBy >> 8 == 19 }
    private var unixMode: UInt32 { isFromUnix ? externalAttributes >> 16 : 0 }

    internal var isDirectory: Bool {
        lastNameByte == 0x2F || lastNameByte == 0x5C || unixMode & 0o170000 == 0o040000
            || (!isFromUnix && externalAttributes & 0x10 != 0)
    }

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

    internal mutating func setPermissions(_ permissions: UInt16) {
        let type: UInt32 = isSymbolicLink ? 0o120000 : isDirectory ? 0o040000 : 0o100000
        versionMadeBy = Self.madeByUnix
        externalAttributes = (type | UInt32(permissions & 0o7777)) << 16 | (isDirectory ? 0x10 : 0)
        unwritten.insert(.attributes)
    }

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

/// Dates as DOS and ZIP store them: local time, two-second steps, from 1980.
internal enum DOSTime {
    internal static func date(time: UInt16, date: UInt16) -> Date {
        var components = DateComponents()
        components.year = 1_980 + Int(date >> 9)
        components.month = max(1, Int(date >> 5 & 0xF))
        components.day = max(1, Int(date & 0x1F))
        components.hour = Int(time >> 11)
        components.minute = Int(time >> 5 & 0x3F)
        components.second = Int(time & 0x1F) * 2
        // Every field is in a range the Gregorian calendar takes (a year from 1980 to 2107, a
        // month and a day of at least 1, an hour below 32, minutes and seconds below 64; larger
        // values roll over into the next unit), so a date always comes out.
        // swiftlint:disable:next force_unwrapping
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    internal static func encode(_ date: Date) -> (time: UInt16, date: UInt16) {
        guard date.timeIntervalSince1970.isFinite else {
            return (0, 0x21)
        }
        let calendar = Calendar(identifier: .gregorian)
        func part(_ component: Calendar.Component) -> UInt16 { UInt16(calendar.component(component, from: date)) }
        let year = calendar.component(.year, from: date)
        guard year >= 1_980 else {
            return (0, 0x21)
        }
        let day = UInt16(min(year - 1_980, 127)) << 9 | part(.month) << 5 | part(.day)
        let time = part(.hour) << 11 | part(.minute) << 5 | part(.second) / 2
        return (time, day)
    }
}

/// How the members of a new ZIP are encrypted.
internal enum ZipEncryption: Equatable {
    /// AES with a 256-bit key as WinZip defined it (AE-2): what protects the contents. Opened
    /// by 7-Zip, WinZip, Keka, The Unarchiver and libarchive; not by the old `unzip`.
    case aes256
    /// The traditional ZIP encryption: every unzip program opens it, and anyone who knows a
    /// few bytes of a member can break it in minutes. Only for exchange with old programs.
    case legacy
}

/// WinZip's AES encryption of ZIP members (methods AE-1 and AE-2).
///
/// A member is stored with method 99; an extra field says how strong the key is and how the data
/// was compressed. Its data is a salt, two bytes that tell a wrong password at once, the contents
/// encrypted with AES in counter mode, and ten bytes of an HMAC-SHA1 over the encrypted bytes,
/// which proves both the password and that nothing was changed.
internal enum ZipAES {
    /// The extra field of an AES member.
    internal struct Field: Equatable {
        /// 1 keeps the CRC of the contents (AE-1); 2 leaves it out (AE-2).
        internal var version: UInt16 = 2
        /// 1, 2, 3: keys of 128, 192, 256 bits.
        internal var strength: UInt8 = 3
        /// How the contents were compressed before they were encrypted.
        internal var method: UInt16 = ZipRecord.methodDeflate

        internal var keyLength: Int { 8 * (Int(strength) + 1) }
        internal var saltLength: Int { keyLength / 2 }
        /// What the encryption adds to a member's data.
        internal var overhead: UInt64 { UInt64(saltLength + ZipAES.verifierLength + ZipAES.macLength) }

        internal var encoded: Data {
            var data = Data()
            data.appendLE(ZipAES.extraID)
            data.appendLE(UInt16(7))
            data.appendLE(version)
            data.append(contentsOf: [0x41, 0x45])
            data.append(strength)
            data.appendLE(method)
            return data
        }

        internal init(method: UInt16) {
            self.method = method
        }

        internal init?(extra: Data) {
            guard let field = ZipRecord.field(ZipAES.extraID, in: extra), field.count >= 7 else {
                return nil
            }
            var reader = ByteReader(field)
            version = reader.u16()
            _ = reader.u16()
            strength = reader.u8()
            method = reader.u16()
            guard (1...3).contains(strength), version == 1 || version == 2 else {
                return nil
            }
        }
    }

    /// The cipher of one member: counter mode with the counter WinZip uses (little-endian,
    /// starting at one), and the running HMAC over the encrypted bytes.
    ///
    /// Used by one thread.
    internal final class Cipher {
        private var cryptor: CCCryptorRef?
        private var mac = CCHmacContext()
        private var counter: UInt64 = 0
        private var stream = [UInt8](repeating: 0, count: 16)
        private var used = 16
        /// The two bytes that follow the salt.
        internal let verifier: Data

        /// Derives the keys (PBKDF2 with HMAC-SHA1, 1000 rounds, as the format fixes it).
        internal init(password: String, salt: Data, keyLength: Int) throws {
            var derived = [UInt8](repeating: 0, count: 2 * keyLength + ZipAES.verifierLength)
            let secret = Array(password.utf8)
            let status = secret.withUnsafeBufferPointer { secret -> Int32 in
                secret.withMemoryRebound(to: CChar.self) { secret in
                    salt.withUnsafeBytes { salt in
                        CCKeyDerivationPBKDF(
                            CCPBKDFAlgorithm(kCCPBKDF2),
                            secret.baseAddress,
                            secret.count,
                            salt.bindMemory(to: UInt8.self).baseAddress,
                            salt.count,
                            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                            1_000,
                            &derived,
                            derived.count
                        )
                    }
                }
            }
            verifier = Data(derived[(2 * keyLength)...])
            let made = CCCryptorCreate(
                CCOperation(kCCEncrypt),
                CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionECBMode),
                derived,
                keyLength,
                nil,
                &cryptor
            )
            // Either fails only for a key length AES does not know.
            guard status == kCCSuccess, made == kCCSuccess, cryptor != nil else {
                throw ArchiveError.unsupported("AES encryption")
            }
            derived.withUnsafeBufferPointer {
                CCHmacInit(&mac, CCHmacAlgorithm(kCCHmacAlgSHA1), $0.baseAddress! + keyLength, keyLength)
            }
        }

        /// Counter mode is its own inverse: the same pass encrypts and decrypts.
        private func crypt(_ bytes: UnsafeMutableRawBufferPointer) {
            var index = 0
            while index < bytes.count {
                if used == 16 {
                    // The key stream for everything that is left, in one call.
                    let blocks = (bytes.count - index + 15) / 16
                    var counters = [UInt8](repeating: 0, count: blocks * 16)
                    for block in 0..<blocks {
                        counter &+= 1
                        var value = counter.littleEndian
                        withUnsafeBytes(of: &value) { source in
                            for byte in 0..<8 { counters[block * 16 + byte] = source[byte] }
                        }
                    }
                    var moved = 0
                    var keys = [UInt8](repeating: 0, count: blocks * 16)
                    CCCryptorUpdate(cryptor, counters, counters.count, &keys, keys.count, &moved)
                    let whole = (bytes.count - index) / 16
                    for offset in 0..<(whole * 16) { bytes[index + offset] ^= keys[offset] }
                    index += whole * 16
                    if index < bytes.count {
                        stream = Array(keys[(whole * 16)...])
                        used = 0
                    }
                    continue
                }
                bytes[index] ^= stream[used]
                used += 1
                index += 1
            }
        }

        internal func encrypt(_ data: Data) -> Data {
            var output = data
            output.withUnsafeMutableBytes { crypt($0) }
            output.withUnsafeBytes { CCHmacUpdate(&mac, $0.baseAddress, $0.count) }
            return output
        }

        internal func decrypt(_ data: inout Data) {
            data.withUnsafeBytes { CCHmacUpdate(&mac, $0.baseAddress, $0.count) }
            data.withUnsafeMutableBytes { crypt($0) }
        }

        /// The ten bytes that end the member.
        ///
        /// Asked once, at the end.
        internal func authentication() -> Data {
            var full = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
            CCHmacFinal(&mac, &full)
            return Data(full.prefix(ZipAES.macLength))
        }

        deinit {
            if let cryptor { CCCryptorRelease(cryptor) }
        }
    }

    /// Encrypts one new member: `header`, then the encrypted contents, then `trailer()`.
    internal final class Encryptor {
        internal let field: Field
        internal let header: Data
        private let cipher: Cipher

        internal init(password: String, method: UInt16) throws {
            field = Field(method: method)
            // From the system's generator of random numbers that are fit for keys.
            let salt = Data((0..<field.saltLength).map { _ in UInt8.random(in: .min ... .max) })
            cipher = try Cipher(password: password, salt: salt, keyLength: field.keyLength)
            header = salt + cipher.verifier
        }

        internal func encrypt(_ data: Data) -> Data { cipher.encrypt(data) }

        internal func trailer() -> Data { cipher.authentication() }
    }

    internal static let method: UInt16 = 99
    internal static let extraID: UInt16 = 0x9901
    internal static let macLength = 10
    internal static let verifierLength = 2
}

extension ZipRecord {
    /// What the extra field says about an AES member; nil for every other member.
    internal var aes: ZipAES.Field? { method == ZipAES.method ? ZipAES.Field(extra: extra) : nil }

    /// Marks a new member as AES-encrypted.
    ///
    /// Its checksum is left out (AE-2): the HMAC proves the contents, and a CRC would tell an
    /// attacker something about them.
    internal mutating func setAES(_ field: ZipAES.Field) {
        flags |= Self.flagEncrypted
        method = ZipAES.method
        crc = 0
        extra = Self.fitting(Self.removing(ZipAES.extraID, from: extra), into: 0xFFFF - 11)
        extra.append(field.encoded)
    }
}

/// Decrypts an AES member while it is read, and checks its authentication code at the end.
internal final class ZipAESDecryptStream: ByteStream {
    private let source: any ByteStream
    private let cipher: ZipAES.Cipher
    private var left: UInt64
    private var checked = false
    private let name: String
    private let onFailure: (() -> Void)?

    /// Reads the salt and checks the two bytes behind it. `length` is the member's whole
    /// stored size. `onFailure` is told when the data turns out not to be what was encrypted
    /// with this password, before the error is thrown.
    internal init(
        _ source: any ByteStream,
        length: UInt64,
        field: ZipAES.Field,
        password: String,
        name: String,
        onFailure: (() -> Void)?
    ) throws {
        self.source = source
        self.name = name
        self.onFailure = onFailure
        guard length >= field.overhead else {
            throw ArchiveError.damaged("the encryption header of \(name) is missing")
        }
        let head = try source.readFully(field.saltLength + ZipAES.verifierLength)
        guard head.count == field.saltLength + ZipAES.verifierLength else {
            throw ArchiveError.damaged("the encryption header of \(name) is missing")
        }
        cipher = try ZipAES.Cipher(
            password: password,
            salt: Data(head.prefix(field.saltLength)),
            keyLength: field.keyLength
        )
        guard Data(head.suffix(ZipAES.verifierLength)) == cipher.verifier else {
            throw ArchiveError.wrongPassword(name)
        }
        left = length - field.overhead
    }

    internal func read(upToCount count: Int) throws -> Data? {
        if left > 0 {
            guard var block = try source.read(upToCount: Int(min(UInt64(max(count, 1)), left))) else {
                throw ArchiveError.damaged("the data of \(name) is cut off")
            }
            left -= UInt64(block.count)
            cipher.decrypt(&block)
            return block
        }
        if !checked {
            checked = true
            let stored = try source.readFully(ZipAES.macLength)
            if stored != cipher.authentication() {
                onFailure?()
                throw ArchiveError.crcMismatch(name)
            }
        }
        return nil
    }

    internal func close() { source.close() }
}

/// The traditional ZIP encryption (PKWARE "ZipCrypto").
///
/// It is weak (see `ZipEncryption.legacy`), but it is what every unzip program can open (spec 08 ›
/// Encryption).
internal struct ZipCrypto {
    private static let table: [UInt32] = (0..<256)
        .map { index -> UInt32 in
            (0..<8).reduce(UInt32(index)) { value, _ in value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        }

    internal static let headerSize = 12

    private var keys: (UInt32, UInt32, UInt32) = (0x1234_5678, 0x2345_6789, 0x3456_7890)

    internal init(password: String) {
        for byte in password.utf8 { update(byte) }
    }

    private mutating func update(_ byte: UInt8) {
        keys.0 = Self.table[Int((keys.0 ^ UInt32(byte)) & 0xFF)] ^ (keys.0 >> 8)
        keys.1 = (keys.1 &+ (keys.0 & 0xFF)) &* 134_775_813 &+ 1
        keys.2 = Self.table[Int((keys.2 ^ (keys.1 >> 24)) & 0xFF)] ^ (keys.2 >> 8)
    }

    /// Both directions work on the block itself; the keys are kept in registers for the loop.
    private mutating func crypt(_ data: inout Data, decrypting: Bool) {
        var (key0, key1, key2) = keys
        Self.table.withUnsafeBufferPointer { table in
            data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
                for index in 0..<bytes.count {
                    let value = (key2 | 2) & 0xFFFF
                    let given = bytes[index]
                    let result = given ^ UInt8(truncatingIfNeeded: (value &* (value ^ 1)) >> 8)
                    bytes[index] = result
                    let plain = decrypting ? result : given
                    key0 = table[Int((key0 ^ UInt32(plain)) & 0xFF)] ^ (key0 >> 8)
                    key1 = (key1 &+ (key0 & 0xFF)) &* 134_775_813 &+ 1
                    key2 = table[Int((key2 ^ (key1 >> 24)) & 0xFF)] ^ (key2 >> 8)
                }
            }
        }
        keys = (key0, key1, key2)
    }

    internal mutating func decrypt(_ data: inout Data) { crypt(&data, decrypting: true) }

    internal mutating func encrypt(_ data: inout Data) { crypt(&data, decrypting: false) }

    internal mutating func decrypt(_ data: Data) -> Data {
        var output = data
        crypt(&output, decrypting: true)
        return output
    }

    internal mutating func encrypt(_ data: Data) -> Data {
        var output = data
        crypt(&output, decrypting: false)
        return output
    }

    /// The twelve bytes in front of the data: random, ending in the byte a reader checks the
    /// password with.
    internal mutating func header(check: UInt8) -> Data {
        var bytes = (0..<Self.headerSize - 1).map { _ in UInt8.random(in: 0...255) }
        bytes.append(check)
        return encrypt(Data(bytes))
    }
}

/// Decrypts a member while it is read.
internal final class ZipDecryptStream: ByteStream {
    private let source: any ByteStream
    private var crypto: ZipCrypto

    /// Reads and checks the encryption header. `check` is the byte the header must end in.
    internal init(_ source: any ByteStream, password: String, check: UInt8, name: String) throws {
        self.source = source
        crypto = ZipCrypto(password: password)
        let header = crypto.decrypt(try source.readFully(ZipCrypto.headerSize))
        guard header.count == ZipCrypto.headerSize else {
            throw ArchiveError.damaged("the encryption header of \(name) is missing")
        }
        guard header.last == check else { throw ArchiveError.wrongPassword(name) }
    }

    internal func read(upToCount count: Int) throws -> Data? {
        guard var block = try source.read(upToCount: count) else {
            return nil
        }
        crypto.decrypt(&block)
        return block
    }

    internal func close() { source.close() }
}

/// Checks the CRC of what passes through, at the end of the stream.
internal final class CRCCheckStream: ByteStream {
    private let source: any ByteStream
    private let expected: UInt32
    private let name: String
    private var crc: UInt32 = 0
    private var checked = false
    private let onFailure: (() -> Void)?

    /// `onFailure` is told when the data turns out wrong, whether it cannot be decoded or
    /// has the wrong checksum, before the error is thrown.
    internal init(_ source: any ByteStream, expected: UInt32, name: String, onFailure: (() -> Void)?) {
        self.source = source
        self.expected = expected
        self.name = name
        self.onFailure = onFailure
    }

    internal func read(upToCount count: Int) throws -> Data? {
        let block: Data?
        do {
            block = try source.read(upToCount: count)
        } catch {
            onFailure?()
            throw error
        }
        if let block {
            crc = CRC32.update(crc, block)
            return block
        }
        if !checked {
            checked = true
            if crc != expected {
                onFailure?()
                throw ArchiveError.crcMismatch(name)
            }
        }
        return nil
    }

    internal func close() { source.close() }
}

/// Reads the directory of a ZIP archive.
///
/// Only the end of the file is read, however large the archive is: the members' data is touched
/// when one of them is opened.
internal enum ZipDirectory {
    internal struct Contents {
        internal var records: [ZipRecord]
        internal var comment: Data
        /// True when the archive uses the 64-bit end records.
        internal var isZip64: Bool
        /// Where the directory starts in the file: the members lie in front of it.
        internal var directoryOffset: UInt64
    }

    private static let endSignature: UInt32 = 0x0605_4B50
    private static let end64Signature: UInt32 = 0x0606_4B50
    private static let locator64Signature: UInt32 = 0x0706_4B50
    private static let centralSignature: UInt32 = 0x0201_4B50
    internal static let localSignature: UInt32 = 0x0403_4B50

    /// `maxEntries` bounds what is read into memory; `check` is called now and then while a
    /// long directory is read, and may throw to end the reading.
    internal static func read(_ file: RandomAccessFile, maxEntries: Int, check: (() throws -> Void)?)
        throws
        -> Contents
    {
        var records: [ZipRecord] = []
        var contents = try scan(file, maxEntries: maxEntries, check: check, expecting: { records.reserveCapacity($0) })
        { records.append($0) }
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
        // The end record is the last thing in the file, followed only by a comment of up to 64 KB.
        let tailSize = Int(min(file.size, 22 + 0xFFFF))
        let tailStart = file.size - UInt64(tailSize)
        let tail = try file.read(at: tailStart, count: tailSize)
        guard tail.count >= 22 else { throw ArchiveError.damaged("the file is too short for a ZIP archive") }
        var endIndex: Int?
        var index = tail.count - 22
        while index >= 0 {
            if tail[index] == 0x50, tail[index + 1] == 0x4B, tail[index + 2] == 0x05, tail[index + 3] == 0x06 {
                let commentLength = Int(tail[index + 20]) | Int(tail[index + 21]) << 8
                // A comment longer than what follows: the signature is part of a comment, the record is further back.
                if index + 22 + commentLength > tail.count {
                    index -= 1
                    continue
                }
                endIndex = index
                break
            }
            index -= 1
        }
        guard let endIndex else { throw ArchiveError.damaged("the ZIP directory was not found") }
        var end = ByteReader(tail.subdata(in: endIndex..<tail.count))
        _ = end.u32()
        let (disk, directoryDisk) = (end.u16(), end.u16())
        _ = end.u16()
        var entryCount = UInt64(end.u16())
        var directorySize = UInt64(end.u32())
        var directoryOffset = UInt64(end.u32())
        let comment = end.bytes(Int(end.u16()))
        guard disk == directoryDisk else { throw ArchiveError.unsupported("An archive split over several disks") }

        // Where the directory ends: at the end record, or at the 64-bit end record before it.
        var directoryEnd = tailStart + UInt64(endIndex)
        var isZip64 = false
        if directoryEnd >= 20 {
            var locator = ByteReader(try file.read(at: directoryEnd - 20, count: 20))
            if locator.u32() == locator64Signature {
                _ = locator.u32()
                var end64Offset = locator.u64()
                var end64 = ByteReader(try file.read(at: end64Offset, count: 56))
                var found = end64.u32() == end64Signature
                if !found, directoryEnd >= 76 {
                    // Behind a self-extracting program every stored offset is too small by the
                    // program's length; the record itself lies right in front of its locator.
                    end64Offset = directoryEnd - 76
                    end64 = ByteReader(try file.read(at: end64Offset, count: 56))
                    found = end64.u32() == end64Signature
                }
                if found {
                    _ = end64.u64()
                    _ = end64.u32()
                    _ = end64.u64()
                    _ = end64.u64()
                    entryCount = end64.u64()
                    directorySize = end64.u64()
                    directoryOffset = end64.u64()
                    directoryEnd = end64Offset
                    isZip64 = true
                }
            }
        }
        guard directorySize <= directoryEnd else {
            throw ArchiveError.damaged("the ZIP directory is larger than the file")
        }
        // Data in front of the archive (a self-extracting program) shifts every offset.
        let actualStart = directoryEnd - directorySize
        let shift = actualStart >= directoryOffset ? actualStart - directoryOffset : 0
        guard directorySize <= 1 << 31 else { throw ArchiveError.unsupported("A ZIP directory of more than 2 GB") }
        // (A file that has become shorter since it was opened delivers less: then the count of
        // records below does not fit.)
        let directory = try file.read(at: actualStart, count: Int(directorySize))

        var count = 0
        // No more than the directory has room for, whatever the end record claims.
        expecting(Int(min(entryCount, directorySize / 46, UInt64(clamping: maxEntries))))
        var reader = ByteReader(directory)
        while reader.remaining >= 46 {
            guard reader.u32() == centralSignature else { break }
            guard count < maxEntries else {
                throw ArchiveError.unsupported("An archive with more than \(maxEntries) entries")
            }
            if count & 0x1FFF == 0x1FFF { try check?() }
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
            count += 1
            try each(record)
        }
        guard UInt64(count) == entryCount || entryCount == 0xFFFF else {
            throw ArchiveError.damaged("the ZIP directory lists \(entryCount) files but holds \(count)")
        }
        return Contents(records: [], comment: comment, isZip64: isZip64, directoryOffset: actualStart)
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

/// Writes a ZIP archive front to back: members, then the directory.
///
/// Used by one thread.
internal final class ZipWriter {
    /// A member whose header was written and whose data is being appended.
    internal struct OpenMember {
        fileprivate let offset: UInt64
        fileprivate let wide: Bool
        fileprivate let localExtra: Data
    }

    private let output: OutputFile
    private let limits: ZipLimits
    private var written: [(record: ZipRecord, offset: UInt64)] = []
    /// True once anything needed the 64-bit format.
    internal private(set) var usedZip64 = false

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
            header.appendLE(
                record.compressedSize > limits.maxField ? UInt32(0xFFFF_FFFF) : UInt32(record.compressedSize)
            )
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
            try output.write(header)
        }
        let directorySize = output.position - directoryOffset
        let needs64 =
            written.count > limits.maxEntries || directorySize > limits.maxField || directoryOffset > limits.maxField
        if needs64 {
            usedZip64 = true
            let end64Offset = output.position
            var end64 = Data()
            end64.appendLE(UInt32(0x0606_4B50))
            end64.appendLE(UInt64(44))
            end64.appendLE(UInt16(45))
            end64.appendLE(UInt16(45))
            end64.appendLE(UInt32(0))
            end64.appendLE(UInt32(0))
            end64.appendLE(UInt64(written.count))
            end64.appendLE(UInt64(written.count))
            end64.appendLE(directorySize)
            end64.appendLE(directoryOffset)
            end64.appendLE(UInt32(0x0706_4B50))
            end64.appendLE(UInt32(0))
            end64.appendLE(end64Offset)
            end64.appendLE(UInt32(1))
            try output.write(end64)
        }
        var end = Data()
        end.appendLE(UInt32(0x0605_4B50))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(0))
        let count = written.count > limits.maxEntries ? UInt16(0xFFFF) : UInt16(written.count)
        end.appendLE(count)
        end.appendLE(count)
        end.appendLE(directorySize > limits.maxField ? UInt32(0xFFFF_FFFF) : UInt32(directorySize))
        end.appendLE(directoryOffset > limits.maxField ? UInt32(0xFFFF_FFFF) : UInt32(directoryOffset))
        end.appendLE(UInt16(min(comment.count, 0xFFFF)))
        end.append(comment.prefix(0xFFFF))
        try output.write(end)
    }
}

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

        case .none:
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
