import Foundation

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

    /// The next block of the source, at most `count` bytes; nil at its end, once the checksum is right.
    ///
    /// Throws `ArchiveError.crcMismatch` at the end when the checksum is wrong.
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

    /// Closes the source.
    internal func close() { source.close() }

    deinit {
        // Nothing to release.
    }
}
