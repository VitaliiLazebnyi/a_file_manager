import Foundation

/// The optional parts of a GZIP header: the original file name and time.
internal struct GzipHeader {
    /// The name of the file that was compressed, when the header carries it.
    internal var name: String?
    /// The time of the file that was compressed; nil when the header gives none (zero).
    internal var modified: Date?

    /// The header at the start of `data`; nil when `data` does not start with a GZIP header.
    internal init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 10, bytes[0] == 0x1F, bytes[1] == 0x8B else {
            return nil
        }
        let flags = bytes[3]
        let time = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
        if time != 0 { modified = Date(timeIntervalSince1970: TimeInterval(time)) }
        var index = 10
        if flags & 4 != 0, bytes.count >= index + 2 { index += 2 + Int(bytes[index]) + Int(bytes[index + 1]) << 8 }
        if flags & 8 != 0, index < bytes.count, let end = bytes[index...].firstIndex(of: 0) {
            name =
                String(bytes: bytes[index..<end], encoding: .utf8)
                ?? String(bytes: bytes[index..<end], encoding: .isoLatin1)
        }
    }
}
