import Foundation

/// The traditional ZIP encryption (PKWARE "ZipCrypto").
///
/// It is weak (see `ZipEncryption.legacy`), but it is what every unzip program can open (spec 08 ›
/// Encryption).
internal struct ZipCrypto {
    private static let table: [UInt32] = (0..<256)
        .map { index -> UInt32 in
            (0..<8).reduce(UInt32(index)) { value, _ in value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        }

    /// The size of the encryption header in front of a member's data.
    internal static let headerSize = 12

    // The three keys of the cipher, which every byte of plain text changes.
    private var key0: UInt32 = 0x1234_5678
    private var key1: UInt32 = 0x2345_6789
    private var key2: UInt32 = 0x3456_7890

    /// The cipher with its keys set up from the password.
    internal init(password: String) {
        for byte in password.utf8 { update(byte) }
    }

    private mutating func update(_ byte: UInt8) {
        key0 = Self.table[Int((key0 ^ UInt32(byte)) & 0xFF)] ^ (key0 >> 8)
        key1 = (key1 &+ (key0 & 0xFF)) &* 134_775_813 &+ 1
        key2 = Self.table[Int((key2 ^ (key1 >> 24)) & 0xFF)] ^ (key2 >> 8)
    }

    /// Both directions work on the block itself; the keys are kept in registers for the loop.
    private mutating func crypt(_ data: inout Data, decrypting: Bool) {
        var (first, second, third) = (key0, key1, key2)
        Self.table.withUnsafeBufferPointer { table in
            data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
                for index in 0..<bytes.count {
                    let value = (third | 2) & 0xFFFF
                    let given = bytes[index]
                    let result = given ^ UInt8(truncatingIfNeeded: (value &* (value ^ 1)) >> 8)
                    bytes[index] = result
                    let plain = decrypting ? result : given
                    first = table[Int((first ^ UInt32(plain)) & 0xFF)] ^ (first >> 8)
                    second = (second &+ (first & 0xFF)) &* 134_775_813 &+ 1
                    third = table[Int((third ^ (second >> 24)) & 0xFF)] ^ (third >> 8)
                }
            }
        }
        (key0, key1, key2) = (first, second, third)
    }

    /// Decrypts a block in place, in order.
    internal mutating func decrypt(_ data: inout Data) { crypt(&data, decrypting: true) }

    /// Encrypts a block in place, in order.
    internal mutating func encrypt(_ data: inout Data) { crypt(&data, decrypting: false) }

    /// A block decrypted, in order.
    internal mutating func decrypt(_ data: Data) -> Data {
        var output = data
        crypt(&output, decrypting: true)
        return output
    }

    /// A block encrypted, in order.
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
