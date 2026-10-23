import Foundation

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

    /// The next decrypted block, at most `count` bytes; nil at the end.
    internal func read(upToCount count: Int) throws -> Data? {
        guard var block = try source.read(upToCount: count) else {
            return nil
        }
        crypto.decrypt(&block)
        return block
    }

    /// Closes the source.
    internal func close() { source.close() }

    deinit {
        // Nothing to release.
    }
}
