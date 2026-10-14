import FuzzCore

/// Writes the checksum of the header block at `block`, as a TAR writer does.
internal func tarFixChecksum(_ bytes: inout [UInt8], block: Int) {
    guard block + 512 <= bytes.count else {
        return
    }
    var sum = 0
    for index in 0..<512 {
        sum += (148..<156).contains(index) ? 32 : Int(bytes[block + index])
    }
    let text = Array(String(sum, radix: 8).utf8)
    let padded = [UInt8](repeating: 48, count: max(0, 6 - text.count)) + text
    for (offset, byte) in padded.prefix(6).enumerated() {
        bytes[block + 148 + offset] = byte
    }
    bytes[block + 154] = 0
    bytes[block + 155] = 32
}

/// Blocks that are, or were, headers: "ustar" where the magic belongs.
internal func tarHeaders(_ bytes: [UInt8]) -> [Int] {
    var out: [Int] = []
    var block = 0
    while block + 512 <= bytes.count {
        if Array(bytes[(block + 257)..<(block + 262)]) == [117, 115, 116, 97, 114] {
            out.append(block)
        }
        block += 512
    }
    if out.isEmpty, bytes.count >= 512 {
        out.append(0)
    }
    return out
}

/// The offsets of the size, mode, time and sparse fields of every header.
internal func tarFields(_ bytes: [UInt8]) -> [Int] {
    tarHeaders(bytes).flatMap { [$0 + 124, $0 + 128, $0 + 136, $0 + 100, $0 + 483, $0 + 386, $0 + 398] }
}

/// Writes `text` into the field of `length` bytes at `offset`, padded with zero bytes.
internal func putText(_ text: [UInt8], _ bytes: inout [UInt8], at offset: Int, length: Int) {
    for index in 0..<length where offset + index < bytes.count {
        bytes[offset + index] = index < text.count ? text[index] : 0
    }
}

/// Changes one field of a header (and fixes its checksum), or fixes every checksum.
internal func tarCustom(_ bytes: inout [UInt8], _ rng: inout Rng) {
    let heads = tarHeaders(bytes)
    guard !heads.isEmpty else {
        return
    }
    if rng.chance(6) {
        for head in heads {
            tarFixChecksum(&bytes, block: head)
        }
        return
    }
    let head = rng.pick(heads)
    guard head + 512 <= bytes.count else {
        return
    }
    mutateTarHeader(&bytes, head, &rng)
    tarFixChecksum(&bytes, block: head)
}

/// One field of the header at `head`.
private func mutateTarHeader(_ bytes: inout [UInt8], _ head: Int, _ rng: inout Rng) {
    switch rng.below(9) {
    case 0, 1:  // the size: octal, or binary with the top bit
        mutateTarSize(&bytes, head, &rng)

    case 2:  // the type
        bytes[head + 156] = rng.pick([48, 49, 50, 51, 52, 53, 54, 55, 76, 75, 120, 103, 83, 0, 77, 78, 86, 88, 65])

    case 3:  // the name
        mutateTarName(&bytes, head, &rng)

    case 4:  // the link target
        let targets = ["../canary", "..", "/", "../canary/keep.txt", "ok.txt", ".", "", "ln", "hl", "../../", "a/../.."]
        putText(rng.pick(targets.map { Array($0.utf8) }), &bytes, at: head + 157, length: 100)
        if rng.chance(2) {
            bytes[head + 156] = rng.chance(2) ? 49 : 50
        }

    case 5:  // the prefix
        putText(rng.pick(kHostileNames), &bytes, at: head + 345, length: 155)

    case 6:  // mode and time
        let text = Array(String(rng.pick(Mutate.interesting), radix: 8).utf8.prefix(11))
        let offset = head + (rng.chance(2) ? 100 : 136)
        putText(text, &bytes, at: offset, length: rng.chance(2) ? 8 : 12)

    case 7:  // the old GNU sparse fields
        bytes[head + 156] = 83
        bytes[head + 482] = rng.chance(2) ? 1 : 0
        putText(
            Array(String(rng.pick(Mutate.interesting), radix: 8).utf8.prefix(11)),
            &bytes,
            at: head + 483,
            length: 12
        )

    default:  // a pax record in the block that follows
        writePaxRecord(&bytes, head, &rng)
    }
}

/// The name field: a way out written over its start, or the whole name, ending in `pwn.txt`.
private func mutateTarName(_ bytes: inout [UInt8], _ head: Int, _ rng: inout Rng) {
    let name = rng.pick(kHostileNames)
    if rng.chance(2) {
        for (offset, byte) in name.enumerated() where offset < 100 {
            bytes[head + offset] = byte
        }
    } else {
        putText(name + Array("pwn.txt".utf8), &bytes, at: head, length: 100)
    }
}

/// The size field: a number in binary with the top bit, or in octal.
private func mutateTarSize(_ bytes: inout [UInt8], _ head: Int, _ rng: inout Rng) {
    if rng.chance(2) {
        let value = rng.pick(Mutate.interesting)
        bytes[head + 124] = rng.chance(4) ? 0xFF : 0x80
        for offset in 0..<3 {
            bytes[head + 125 + offset] = rng.chance(8) ? 0xFF : 0
        }
        Mutate.put(value, width: 8, at: head + 128, bigEndian: true, in: &bytes)
    } else {
        let sizes: [UInt64] = [
            0, 1, 5, 511, 512, 513, 0o77777777777, 0o7777777777, 1 << 20, UInt64(bytes.count),
            UInt64(max(0, bytes.count - head - 512)), UInt64(max(0, bytes.count - head - 511))
        ]
        putText(Array(String(rng.pick(sizes), radix: 8).utf8), &bytes, at: head + 124, length: 12)
    }
}

/// A pax record in the block after the header at `head`, which becomes a pax header.
private func writePaxRecord(_ bytes: inout [UInt8], _ head: Int, _ rng: inout Rng) {
    guard head + 1_024 <= bytes.count else {
        return
    }
    let key = rng.pick([
        "path", "linkpath", "size", "mtime", "GNU.sparse.size", "GNU.sparse.realsize", "GNU.sparse.name",
        "GNU.sparse.map", "GNU.sparse.major", "uid", "SCHILY.xattr.x", "hdrcharset"
    ])
    let value = rng.pick([
        "../canary/pwn", "/abs", "0", "-1", "99999999999999999999", "9223372036854775807", "18446744073709551615",
        "1e308", "nan", "1.5", "", "\0", "x/../../y", String(repeating: "A", count: 300)
    ])
    let body = " \(key)=\(value)\n"
    var length = body.utf8.count + 1
    while String(length).utf8.count + body.utf8.count != length {
        length = String(length).utf8.count + body.utf8.count
    }
    let wrongLengths = ["0", "1", "99999999999999999999", "-5", String(length + 1), String(length - 1)]
    let stated = rng.chance(6) ? rng.pick(wrongLengths) : String(length)
    let record = Array("\(stated)\(body)".utf8)
    putText(record, &bytes, at: head + 512, length: min(512, record.count))
    bytes[head + 156] = rng.chance(4) ? 103 : 120
    putText(Array(String(record.count, radix: 8).utf8), &bytes, at: head + 124, length: 12)
}
