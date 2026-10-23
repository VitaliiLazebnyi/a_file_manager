import Foundation

/// TAR members built by hand, 512 bytes at a time, for archives no tar program would write.
internal enum HandMadeTar {
    /// A regular file `name` (permissions 644) with `text` as its contents, padded to a whole block.
    internal static func file(_ name: String, _ text: String) -> Data {
        var data = header(name: name, type: 48, size: UInt64(text.utf8.count), link: "", mode: 0o644)
        data.append(body(text))
        return data
    }

    /// A link `name` to `target` without contents: a hard link with type 49, a symbolic link with type 50.
    internal static func link(_ name: String, to target: String, type: UInt8) -> Data {
        header(name: name, type: type, size: 0, link: target, mode: 0o644)
    }

    /// One 512-byte header: the name and the link cut at 100 bytes, the numbers in octal, the checksum filled in.
    internal static func header(name: String, type: UInt8, size: UInt64, link: String, mode: UInt64) -> Data {
        var block = [UInt8](repeating: 0, count: 512)
        func put(_ bytes: [UInt8], at offset: Int) {
            for (index, byte) in bytes.enumerated() { block[offset + index] = byte }
        }
        func octal(_ value: UInt64, _ length: Int) -> [UInt8] {
            let digits = String(value, radix: 8)
            return Array((String(repeating: "0", count: length - 1 - digits.count) + digits).utf8)
        }
        put(Array(name.utf8.prefix(100)), at: 0)
        put(octal(mode, 8), at: 100)
        put(octal(size, 12), at: 124)
        put(octal(1_600_000_000, 12), at: 136)
        block[156] = type
        put(Array(link.utf8.prefix(100)), at: 157)
        put(Array("ustar\u{0}00".utf8), at: 257)
        for index in 148..<156 { block[index] = 32 }
        let sum = block.reduce(0) { total, byte in total + Int(byte) }
        put(Array(String(format: "%06o", sum).utf8) + [0, 32], at: 148)
        return Data(block)
    }

    /// `text` padded with zero bytes to a whole number of blocks.
    internal static func body(_ text: String) -> Data {
        var data = Data(text.utf8)
        data.append(Data(count: (512 - data.count % 512) % 512))
        return data
    }
}
