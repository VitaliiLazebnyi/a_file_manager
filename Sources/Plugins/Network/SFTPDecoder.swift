import Foundation

/// Reads the body of a packet.
///
/// Everything comes from the server, so every step is checked.
internal struct SFTPDecoder {
    private let data: Data
    private var offset: Int

    /// Whether everything was read.
    internal var isAtEnd: Bool { offset >= data.endIndex }

    /// A decoder that reads `data` from its start.
    internal init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    /// Reads one byte.
    internal mutating func u8() throws -> UInt8 {
        let byte = try take(1)
        return byte[byte.startIndex]
    }

    /// Reads a 32-bit number, big-endian.
    internal mutating func u32() throws -> UInt32 { try take(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
    /// Reads a 64-bit number, big-endian.
    internal mutating func u64() throws -> UInt64 { try take(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
    /// Reads bytes after their length.
    internal mutating func bytes() throws -> Data { try take(Int(try u32())) }
    /// Reads a text that is not a file name, as UTF-8.
    internal mutating func string() throws -> String { String(repairingUTF8: try bytes()) }

    /// A file name, and the encoding that read it: UTF-8 where the bytes are UTF-8, else
    /// Latin 1, which reads any bytes and writes the same bytes back.
    ///
    /// Read as UTF-8 with replacement characters, such a name could never be sent to the server
    /// again.
    internal mutating func name() throws -> (text: String, encoding: String.Encoding) {
        let raw = Data(try bytes())
        if let text = String(data: raw, encoding: .utf8) {
            return (text, .utf8)
        }
        // Latin 1 is the first 256 code points, one byte each.
        var text = String.UnicodeScalarView()
        text.append(contentsOf: raw.map { Unicode.Scalar($0) })
        return (String(text), .isoLatin1)
    }

    /// Reads attributes; the ones this program does not use are skipped.
    internal mutating func attributes() throws -> SFTPAttributes {
        let flags = try u32()
        var attributes = SFTPAttributes()
        if flags & 1 != 0 { attributes.size = try u64() }
        if flags & 2 != 0 { _ = try take(8) }
        if flags & 4 != 0 { attributes.permissions = try u32() }
        if flags & 8 != 0 {
            _ = try u32()
            attributes.modified = try u32()
        }
        if flags & 0x8000_0000 != 0 {
            for _ in 0..<(try u32()) { _ = (try bytes(), try bytes()) }
        }
        return attributes
    }

    private mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, data.endIndex - offset >= count else {
            throw NetworkError.unexpected("a damaged SFTP packet")
        }
        defer { offset += count }
        return data[offset..<offset + count]
    }
}
