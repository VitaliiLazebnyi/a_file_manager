import FuzzCore

// MARK: - format-aware mutations

/// Names that are a way out of the target folder, or that meet the links planted there.
internal let kHostileNames: [[UInt8]] = [
    "../", "/", "..\\", "../canary/", "./", "//", "..", "a/../", "\0", "ln/", "up/canary/", "C:\\", "~/", "keep.txt",
    "hl", "ln", "up/",
    "..\u{301}/", "/\u{301}../", "x/\u{301}../../canary/"
]
.map { Array($0.utf8) }

/// The ZIP records by the two bytes after "PK": the offsets of their size, count and offset
/// fields, and their fixed length.
private let kZipRecordLayouts: [UInt16: (fields: [Int], length: Int)] = [
    0x0102: ([4, 6, 8, 10, 12, 14, 16, 20, 24, 28, 30, 32, 34, 36, 38, 42], 46),
    0x0304: ([4, 6, 8, 10, 14, 18, 22, 26, 28], 30),
    0x0506: ([4, 6, 8, 10, 12, 16, 20], 22),
    0x0606: ([4, 12, 14, 16, 20, 24, 32, 40, 48], 56),
    0x0607: ([4, 8, 16], 20),
    0x0708: ([4, 8, 12], 16)
]

/// The little-endian number of `width` bytes at `offset`.
internal func readLE(_ bytes: [UInt8], _ offset: Int, _ width: Int) -> UInt64 {
    Mutate.get(width: width, at: offset, bigEndian: false, in: bytes)
}

/// The offsets of the size, count and offset fields of a ZIP file's records.
internal func zipFields(_ bytes: [UInt8]) -> [Int] {
    var out: [Int] = []
    var index = 0
    while index + 4 <= bytes.count {
        let kind = UInt16(bytes[index + 2]) << 8 | UInt16(bytes[index + 3])
        if bytes[index] == 0x50, bytes[index + 1] == 0x4B, let layout = kZipRecordLayouts[kind] {
            let start = index
            out += layout.fields.map { start + $0 }
            index += layout.length
            continue
        }
        // extra fields: zip64 and the time stamps
        if isZipExtraField(bytes, at: index) {
            out += [index + 2, index + 4, index + 12, index + 20]
        }
        index += 1
    }
    return out
}

/// The name of a member, in the directory and in its local header, starts with a way out; or
/// the member's type, flags, method or sizes change.
internal func zipCustom(_ bytes: inout [UInt8], _ rng: inout Rng) {
    let heads = zipHeaders(bytes)
    guard !heads.isEmpty else {
        return
    }
    let head = rng.pick(heads)
    let length = Int(readLE(bytes, head.lengthAt, 2))
    switch rng.below(6) {
    case 0, 1:  // written over the start of the name
        let name = rng.pick(kHostileNames)
        for (offset, byte) in name.enumerated() where offset < length && head.nameAt + offset < bytes.count {
            bytes[head.nameAt + offset] = byte
        }

    case 2:  // inserted, with the length corrected (later offsets shift: the directory is then found or not)
        let name = rng.pick(kHostileNames)
        guard head.nameAt <= bytes.count, length + name.count <= 0xFFFF else {
            return
        }
        bytes.insert(contentsOf: name, at: head.nameAt)
        Mutate.put(UInt64(length + name.count), width: 2, at: head.lengthAt, bigEndian: false, in: &bytes)

    case 3:  // the type of the member: link, folder, device
        setMemberType(&bytes, head, &rng)

    case 4:  // flags and method
        setFlagsAndMethod(&bytes, head, &rng)

    default:  // sizes say "see the zip64 field"
        let offset = bytes[head.start + 2] == 1 ? 20 : 18
        Mutate.put(
            0xFFFF_FFFF,
            width: 4,
            at: head.start + offset + (rng.chance(2) ? 4 : 0),
            bigEndian: false,
            in: &bytes
        )
        if bytes[head.start + 2] == 1, rng.chance(2) {
            Mutate.put(0xFFFF_FFFF, width: 4, at: head.start + 42, bigEndian: false, in: &bytes)
        }
    }
}

/// Whether a zip64 or time stamp extra field may begin at `index`.
private func isZipExtraField(_ bytes: [UInt8], at index: Int) -> Bool {
    let pair = (bytes[index], bytes[index + 1])
    return pair == (1, 0) || pair == (0x55, 0x54) || pair == (0x75, 0x78)
}

/// The directory entries and local headers of a ZIP.
private func zipHeaders(_ bytes: [UInt8]) -> [ZipHeader] {
    var heads: [ZipHeader] = []
    var index = 0
    while index + 4 <= bytes.count {
        if bytes[index] == 0x50, bytes[index + 1] == 0x4B, bytes[index + 2] == 1, bytes[index + 3] == 2 {
            heads.append(ZipHeader(start: index, nameAt: index + 46, lengthAt: index + 28))
        }
        if bytes[index] == 0x50, bytes[index + 1] == 0x4B, bytes[index + 2] == 3, bytes[index + 3] == 4 {
            heads.append(ZipHeader(start: index, nameAt: index + 30, lengthAt: index + 26))
        }
        index += 1
    }
    return heads
}

/// A directory entry's external attributes say link, folder, device or file, made on Unix (or not).
private func setMemberType(_ bytes: inout [UInt8], _ head: ZipHeader, _ rng: inout Rng) {
    guard head.start + 42 <= bytes.count, bytes[head.start + 2] == 1 else {
        return
    }
    let mode: UInt64 = rng.pick([0o120777, 0o040755, 0o100644, 0o020644, 0o104755, 0o060000, 0o010000, 0])
    Mutate.put(mode << 16 | UInt64(rng.below(64)), width: 4, at: head.start + 38, bigEndian: false, in: &bytes)
    bytes[head.start + 5] = rng.chance(4) ? UInt8(rng.below(20)) : 3
}

/// The flags and the method of a header.
private func setFlagsAndMethod(_ bytes: inout [UInt8], _ head: ZipHeader, _ rng: inout Rng) {
    let offset = bytes[head.start + 2] == 1 ? 8 : 6
    let flags: UInt64 = rng.pick([0, 1, 8, 0x41, 0x800, 0x809, 0x2000, 0xFFFF])
    Mutate.put(flags, width: 2, at: head.start + offset, bigEndian: false, in: &bytes)
    let method: UInt64 = rng.pick([0, 8, 9, 12, 14, 99, 0xFFFF])
    Mutate.put(method, width: 2, at: head.start + offset + 2, bigEndian: false, in: &bytes)
}
