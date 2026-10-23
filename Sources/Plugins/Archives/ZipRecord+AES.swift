import Foundation

/// WinZip's AES encryption of a member.
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
