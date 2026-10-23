import Foundation

/// The alphabets of the two older formats, and their lines.
internal enum SixBitText {
    /// A line that is not one of the format: a character outside the alphabet, or too few for its length.
    internal struct NotALine: Error {}

    /// The 64 characters of XXEncode, by value.
    internal static let xxAlphabet = Array("+-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    /// The character of every six-bit value in UUEncode (a backquote for 0).
    private static let uuCharacters: [UInt8] = (0..<64).map { value in value == 0 ? 96 : UInt8(value) + 32 }
    /// The six-bit value of every character in UUEncode; 255 for the others.
    private static let uuValues: [UInt8] = (0..<256)
        .map { code in
            (32...96).contains(code) ? UInt8((code - 32) & 63) : 255
        }
    /// The six-bit value of every character in XXEncode; 255 for the others.
    private static let xxValues: [UInt8] = {
        var values = [UInt8](repeating: 255, count: 256)
        for (index, character) in xxAlphabet.enumerated() {
            values[Int(character)] = UInt8(index)
        }
        return values
    }()

    /// Lines of up to 45 bytes each: a length character, four characters for every three
    /// bytes, CRLF; in XXEncode's alphabet with `xxEncode`, else in UUEncode's.
    internal static func encode(_ data: Data, xxEncode: Bool) -> Data {
        let (full, rest) = data.count.quotientAndRemainder(dividingBy: 45)
        var output = Data(count: full * 63 + (rest > 0 ? 3 + (rest + 2) / 3 * 4 : 0))
        guard !output.isEmpty else {
            return output
        }
        let characters = xxEncode ? xxAlphabet : uuCharacters
        output.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                characters.withUnsafeBufferPointer { table in
                    encodeLines(input.bindMemory(to: UInt8.self), into: out.bindMemory(to: UInt8.self), table: table)
                }
            }
        }
        return output
    }

    /// Writes the lines of `source` into `target`, which has room for exactly them.
    private static func encodeLines(
        _ source: UnsafeBufferPointer<UInt8>,
        into target: UnsafeMutableBufferPointer<UInt8>,
        table: UnsafeBufferPointer<UInt8>
    ) {
        var (position, written) = (0, 0)
        while position < source.count {
            let count = min(45, source.count - position)
            target[written] = table[count]
            written += 1
            var group = 0
            while group < count {
                // A last group of fewer than three bytes is read as if padded with zeros.
                let first = source[position + group]
                let second = group + 1 < count ? source[position + group + 1] : 0
                let third = group + 2 < count ? source[position + group + 2] : 0
                target[written] = table[Int(first >> 2)]
                target[written + 1] = table[Int((first << 4 | second >> 4) & 63)]
                target[written + 2] = table[Int((second << 2 | third >> 6) & 63)]
                target[written + 3] = table[Int(third & 63)]
                written += 4
                group += 3
            }
            target[written] = 13
            target[written + 1] = 10
            written += 2
            position += count
        }
    }

    /// The bytes of one line, in XXEncode's alphabet with `xxEncode`, else in UUEncode's; throws `NotALine`
    /// when the line is not one of this format.
    internal static func decode(_ line: ArraySlice<UInt8>, xxEncode: Bool) throws -> [UInt8] {
        try (xxEncode ? xxValues : uuValues)
            .withUnsafeBufferPointer { table in
                try line.withUnsafeBufferPointer { text in
                    guard let first = text.first, table[Int(first)] != 255 else {
                        throw NotALine()
                    }
                    let count = Int(table[Int(first)])
                    // Every character of the line must belong to the alphabet.
                    for index in 1..<max(text.count, 1) where table[Int(text[index])] == 255 {
                        throw NotALine()
                    }
                    let available = text.count - 1
                    let needed = (count + 2) / 3 * 4
                    // Programs that cut spaces off the end of a line leave UUEncode lines short.
                    guard available >= needed || (!xxEncode && available + 3 >= needed) else {
                        throw NotALine()
                    }
                    return bytes(count, of: text, available: available, table: table)
                }
            }
    }

    /// The `count` bytes of the characters after the length character, `available` of them there (the rest
    /// counts as zero).
    private static func bytes(
        _ count: Int,
        of text: UnsafeBufferPointer<UInt8>,
        available: Int,
        table: UnsafeBufferPointer<UInt8>
    ) -> [UInt8] {
        // An empty array is never made with `unsafeUninitializedCapacity`: for a capacity of zero
        // the standard library writes the count into the storage all empty arrays share, a write
        // that races with any other thread reading an empty array.
        guard count > 0 else {
            return []
        }
        return [UInt8](unsafeUninitializedCapacity: count) { bytes, initialized in
            func six(_ index: Int) -> UInt8 { index < available ? table[Int(text[index + 1])] : 0 }
            var (group, written) = (0, 0)
            while written < count {
                let (first, second, third, fourth) = (six(group), six(group + 1), six(group + 2), six(group + 3))
                bytes[written] = first << 2 | second >> 4
                if written + 1 < count {
                    bytes[written + 1] = second << 4 | third >> 2
                }
                if written + 2 < count {
                    bytes[written + 2] = third << 6 | fourth
                }
                written += 3
                group += 4
            }
            initialized = count
        }
    }
}
