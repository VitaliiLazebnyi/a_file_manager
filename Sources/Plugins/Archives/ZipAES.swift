import CommonCrypto
import Foundation

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

        /// The length of the AES key in bytes.
        internal var keyLength: Int { 8 * (Int(strength) + 1) }
        /// The length of the salt in front of the data in bytes.
        internal var saltLength: Int { keyLength / 2 }
        /// What the encryption adds to a member's data.
        internal var overhead: UInt64 { UInt64(saltLength + ZipAES.verifierLength + ZipAES.macLength) }

        /// The field as the extra data of a header holds it.
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

        /// The field of a new member: AE-2 with a 256-bit key, its contents compressed with `method`.
        internal init(method: UInt16) {
            self.method = method
        }

        /// The field in `extra`; nil when there is none or it is not one this program knows.
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
            // The key of the HMAC follows the key of the cipher.
            let macKey = Array(derived[keyLength..<(2 * keyLength)])
            CCHmacInit(&mac, CCHmacAlgorithm(kCCHmacAlgSHA1), macKey, macKey.count)
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

        /// Encrypts a block of the member, in order, and adds it to the authentication code.
        internal func encrypt(_ data: Data) -> Data {
            var output = data
            output.withUnsafeMutableBytes { crypt($0) }
            output.withUnsafeBytes { CCHmacUpdate(&mac, $0.baseAddress, $0.count) }
            return output
        }

        /// Decrypts a block of the member in place, in order, after adding it to the authentication code.
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
        /// The extra field the member is stored with.
        internal let field: Field
        /// The salt and the password check, which stand in front of the encrypted contents.
        internal let header: Data
        private let cipher: Cipher

        /// Prepares the encryption with a new random salt; throws when AES is not available.
        internal init(password: String, method: UInt16) throws {
            field = Field(method: method)
            // From the system's generator of random numbers that are fit for keys.
            let salt = Data((0..<field.saltLength).map { _ in UInt8.random(in: .min ... .max) })
            cipher = try Cipher(password: password, salt: salt, keyLength: field.keyLength)
            header = salt + cipher.verifier
        }

        /// Encrypts the next block of the contents.
        internal func encrypt(_ data: Data) -> Data { cipher.encrypt(data) }

        /// The authentication code that ends the member; asked once, after the last block.
        internal func trailer() -> Data { cipher.authentication() }

        deinit {
            // Nothing to release.
        }
    }

    /// The method number of an AES member.
    internal static let method: UInt16 = 99
    /// The id of the AES extra field.
    internal static let extraID: UInt16 = 0x9901
    /// The length of the authentication code at the end of a member.
    internal static let macLength = 10
    /// The length of the password check behind the salt.
    internal static let verifierLength = 2
}
