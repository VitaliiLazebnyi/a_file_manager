import Foundation

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

    /// The next decrypted block, at most `count` bytes; nil at the end, once the authentication code
    /// fits.
    ///
    /// Throws `ArchiveError.crcMismatch` at the end when the code shows a wrong password or changed data.
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

    /// Closes the source.
    internal func close() { source.close() }

    deinit {
        // Nothing to release.
    }
}
