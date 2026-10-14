/// The members of a ZIP as its directory names them: flags, method and the extra field of each.
internal struct ZipDirectory {
    /// The members, in the directory's order.
    internal let members: [ZipMember]

    /// Reads the directory of `bytes`; nil without an end record, or when an entry is cut off.
    internal init?(_ bytes: [UInt8]) {
        guard bytes.count >= 22 else {
            return nil
        }
        var end = bytes.count - 22
        while end >= 0, !(bytes[end] == 0x50 && bytes[end + 1] == 0x4B && bytes[end + 2] == 5 && bytes[end + 3] == 6) {
            end -= 1
        }
        guard end >= 0 else {
            return nil
        }
        let count = Int(readLE(bytes, end + 10, 2))
        var offset = Int(readLE(bytes, end + 16, 4))
        var found: [ZipMember] = []
        for _ in 0..<count {
            guard let entry = Self.entry(in: bytes, at: offset) else {
                return nil
            }
            found.append(entry.member)
            offset = entry.next
        }
        members = found
    }

    /// The directory entry at `offset` and where the next one begins; nil when it is not one.
    private static func entry(in bytes: [UInt8], at offset: Int) -> (member: ZipMember, next: Int)? {
        guard offset + 46 <= bytes.count, bytes[offset] == 0x50, bytes[offset + 1] == 0x4B, bytes[offset + 2] == 1,
            bytes[offset + 3] == 2
        else {
            return nil
        }
        let nameLength = Int(readLE(bytes, offset + 28, 2))
        let extraLength = Int(readLE(bytes, offset + 30, 2))
        let commentLength = Int(readLE(bytes, offset + 32, 2))
        let nameStart = offset + 46
        let extraStart = nameStart + nameLength
        guard extraStart + extraLength <= bytes.count else {
            return nil
        }
        let member = ZipMember(
            name: Array(bytes[nameStart..<extraStart]),
            flags: Int(readLE(bytes, offset + 8, 2)),
            method: Int(readLE(bytes, offset + 10, 2)),
            extra: Array(bytes[extraStart..<(extraStart + extraLength)])
        )
        return (member, extraStart + extraLength + commentLength)
    }
}
