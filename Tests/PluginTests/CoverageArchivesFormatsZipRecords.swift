import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// What a ZIP directory record says (names, rights, extra fields, times) and the encryption of members.
@Suite
internal struct CoverageArchivesFormatsZipRecords {
    private typealias Support = CoverageArchivesFormatsSupport

    /// Info-ZIP's Unicode name field for `name`.
    private static func unicodeField(_ name: String) -> Data {
        var field = Data()
        field.appendLE(UInt16(0x7075))
        field.appendLE(UInt16(5 + name.utf8.count))
        field.append(contentsOf: [1, 0, 0, 0, 0])
        field.append(Data(name.utf8))
        return field
    }

    private static func record(name bytes: [UInt8], flags: UInt16 = 0, extra: Data = Data()) -> ZipRecord {
        var record = ZipRecord()
        record.nameBytes = Data(bytes)
        record.flags = flags
        record.extra = extra
        return record
    }

    /// An AES member as stored: salt, check bytes, the encrypted data, the authentication code.
    private static func aesMember(_ text: String, password: String = "pw") throws -> Data {
        let encryptor = try ZipAES.Encryptor(password: password, method: ZipRecord.methodStored)
        return encryptor.header + encryptor.encrypt(Data(text.utf8)) + encryptor.trailer()
    }

    private static func aesStream(_ data: Data, length: UInt64? = nil, onFailure: (() -> Void)? = nil) throws
        -> ZipAESDecryptStream
    {
        try ZipAESDecryptStream(
            DataStream(data),
            length: length ?? UInt64(data.count),
            field: ZipAES.Field(method: ZipRecord.methodStored),
            password: "pw",
            name: "m",
            onFailure: onFailure
        )
    }

    /// A name that is not marked as UTF-8 takes Info-ZIP's Unicode field, whether its own bytes are valid text or not.
    @Test
    internal func unmarkedNamesTakeTheUnicodeField() {
        let valid = Self.record(name: Array("é".utf8), extra: Self.unicodeField("Ê"))
        #expect(valid.name == "Ê")
        let invalid = Self.record(name: [0x80, 0x41], extra: Self.unicodeField("ü"))
        #expect(invalid.name == "ü" && !invalid.isDirectory)
    }

    /// A name whose bytes begin with a byte-order mark is read as UTF-8, marked or not.
    @Test
    internal func aNameWithAByteOrderMarkIsReadAsUTF8() {
        let bytes: [UInt8] = [0xEF, 0xBB, 0xBF, 0x41]
        #expect(Self.record(name: bytes, flags: ZipRecord.flagUTF8).name == "A")
        #expect(Self.record(name: bytes).name == "A")
    }

    /// A name that is neither UTF-8 nor has a Unicode field is read in the DOS character set.
    @Test
    internal func otherNamesAreReadInTheDOSCharacterSet() {
        #expect(Self.record(name: [0x80, 0x41, 0xE1]).name == "ÇAß")
    }

    /// A folder from DOS that is not read-only may be written to.
    @Test
    internal func aFolderFromDOSMayBeWrittenTo() {
        var folder = Self.record(name: Array("dir".utf8))
        folder.versionMadeBy = 0
        folder.externalAttributes = 0x10
        #expect(folder.isDirectory && folder.permissions == 0o755)
    }

    /// A symbolic link stays one when its rights change.
    @Test
    internal func aLinkStaysALinkWhenItsRightsChange() {
        var link = ZipRecord.new(
            name: "link",
            isDirectory: false,
            modified: Date(),
            permissions: 0o777,
            isSymbolicLink: true
        )
        #expect(link.isSymbolicLink)
        link.setPermissions(0o755)
        #expect(link.isSymbolicLink && link.permissions == 0o755 && link.unwritten.contains(.attributes))
    }

    /// Extra fields that claim more than there is are not read, kept or carried over.
    @Test
    internal func extraFieldsThatClaimTooMuchAreLeftOut() {
        var good = Data()
        good.appendLE(UInt16(1))
        good.appendLE(UInt16(4))
        good.append(contentsOf: [1, 2, 3, 4])
        let broken = Data([2, 0, 100, 0, 1, 2])
        #expect(ZipRecord.field(2, in: good + broken) == nil)
        #expect(ZipRecord.removing(9, from: good + broken) == good)
        #expect(ZipRecord.fitting(broken + good, into: 4).isEmpty)
    }

    /// Fields that do not fit the room are left out, whole, in their order.
    @Test
    internal func fieldsThatDoNotFitAreLeftOut() {
        var first = Data()
        first.appendLE(UInt16(1))
        first.appendLE(UInt16(4))
        first.append(contentsOf: [1, 2, 3, 4])
        var second = Data()
        second.appendLE(UInt16(2))
        second.appendLE(UInt16(6))
        second.append(Data(count: 6))
        #expect(ZipRecord.fitting(first + second, into: 12) == first)
        #expect(ZipRecord.fitting(second + first, into: 12) == second)
    }

    /// A time before 1980 has no DOS form and becomes the first day DOS knows.
    @Test
    internal func aTimeBefore1980BecomesTheFirstDayDOSKnows() {
        let time = DOSTime.encode(Date(timeIntervalSince1970: 0))
        #expect(time.time == 0 && time.date == 0x21)
    }

    /// An AES field that is missing or names an unknown strength is no AES field; other methods have none.
    @Test
    internal func anAESFieldMustBeThereAndKnown() {
        #expect(ZipAES.Field(extra: Data()) == nil)
        var unknown = ZipAES.Field(method: ZipRecord.methodDeflate)
        unknown.strength = 4
        #expect(ZipAES.Field(extra: unknown.encoded) == nil)
        var plain = ZipRecord()
        plain.method = ZipRecord.methodDeflate
        plain.extra = ZipAES.Field(method: ZipRecord.methodDeflate).encoded
        #expect(plain.aes == nil)
    }

    /// A key length AES does not know is refused.
    @Test
    internal func aKeyLengthAESDoesNotKnowIsRefused() {
        #expect(
            Support.failure { _ = try ZipAES.Cipher(password: "secret", salt: Data(count: 8), keyLength: 8) }
                == ArchiveError.unsupported("AES encryption").errorDescription
        )
    }

    /// An AES member shorter than what the encryption adds, or whose header is cut off, is damage.
    @Test
    internal func anAESMemberWithoutItsHeaderIsDamage() {
        let missing = ArchiveError.damaged("the encryption header of m is missing").errorDescription
        #expect(Support.failure { _ = try Self.aesStream(Data(count: 10)) } == missing)
        #expect(Support.failure { _ = try Self.aesStream(Data(count: 10), length: 100) } == missing)
    }

    /// An AES member whose data is cut off is damage.
    @Test
    internal func anAESMemberCutOffIsDamage() throws {
        let member = try Self.aesMember("some text")
        let stream = try Self.aesStream(member.prefix(20), length: UInt64(member.count))
        #expect(
            Support.failure { _ = try stream.readFully(100) }
                == ArchiveError.damaged("the data of m is cut off").errorDescription
        )
    }

    /// An AES member whose authentication code does not fit is reported, and its owner told.
    @Test
    internal func aChangedAESMemberIsReported() throws {
        var member = try Self.aesMember("some text")
        member[member.count - 1] ^= 1
        let told = SharedCounter()
        let stream = try Self.aesStream(member) { told.add(1) }
        #expect(Support.failure { _ = try stream.readFully(100) } == ArchiveError.crcMismatch("m").errorDescription)
        #expect(told.value == 1)
        // Checked once: afterwards the stream has simply ended.
        #expect(try stream.read(upToCount: 10) == nil)
    }

    /// A traditionally encrypted member without its whole header is damage.
    @Test
    internal func aTraditionalMemberWithoutItsHeaderIsDamage() {
        #expect(
            Support.failure {
                _ = try ZipDecryptStream(DataStream(Data(count: 5)), password: "pw", check: 0, name: "m")
            }
                == ArchiveError.damaged("the encryption header of m is missing").errorDescription
        )
    }
}
