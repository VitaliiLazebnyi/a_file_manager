import Foundation

/// Builds the body of a packet: big-endian numbers and length-prefixed strings.
internal struct SFTPEncoder {
    /// What was written so far.
    internal private(set) var data = Data()
    /// The names of the server that are written back as they came (see `NameMemory`).
    internal var names: NameMemory?

    /// Writes one byte.
    internal mutating func u8(_ value: UInt8) { data.append(value) }
    /// Writes a 32-bit number, big-endian.
    internal mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    /// Writes a 64-bit number, big-endian.
    internal mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }

    /// Writes bytes after their length.
    internal mutating func bytes(_ value: Data) {
        u32(UInt32(value.count))
        data.append(value)
    }

    /// Starts a packet: the length, filled in by `finishPacket`, the type and the request number
    /// (none for the first packet, which has none).
    internal mutating func beginPacket(_ type: UInt8, id: UInt32?) {
        u32(0)
        u8(type)
        if let id { u32(id) }
    }

    /// Writes the length at the front, now that the packet is complete.
    internal mutating func finishPacket() {
        let length = UInt32(data.count - 4).bigEndian
        withUnsafeBytes(of: length) { data.replaceSubrange(0..<4, with: $0) }
    }

    /// Names travel as composed UTF-8, which is what servers store, except the names the
    /// server itself spelled another way (decomposed, or not UTF-8 at all): those go back as
    /// the bytes they came as, or they would not name the same file.
    internal mutating func string(_ value: String) {
        guard let names, !names.isEmpty else {
            bytes(Data(value.precomposedStringWithCanonicalMapping.utf8))
            return
        }
        var result = Data()
        for (index, piece) in Array(value.utf8).split(separator: 0x2F, omittingEmptySubsequences: false).enumerated() {
            if index > 0 { result.append(0x2F) }
            let name = String(repairingUTF8: piece)
            if let spelled = names.encoding(of: piece),
                let kept = name.data(using: spelled, allowLossyConversion: false)
            {
                result.append(kept)
            } else {
                result.append(Data(name.precomposedStringWithCanonicalMapping.utf8))
            }
        }
        bytes(result)
    }

    /// Writes the attributes that are set; `SFTPAttributes()` writes none.
    internal mutating func attributes(_ value: SFTPAttributes) {
        u32((value.size != nil ? 1 : 0) | (value.permissions != nil ? 4 : 0) | (value.modified != nil ? 8 : 0))
        if let size = value.size { u64(size) }
        if let permissions = value.permissions { u32(permissions) }
        if let modified = value.modified {
            // Access time and time of change go together; both get the same value.
            u32(modified)
            u32(modified)
        }
    }
}
