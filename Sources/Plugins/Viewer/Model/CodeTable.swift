import Foundation

/// The conversion tables of a code page, built once from the system's converter.
///
/// Immutable after creation, so every thread may read them.
internal struct CodeTable: Sendable {
    /// The tables of one code page while they are built.
    private struct Tables {
        var single = [UInt16](repeating: CodeTable.replacement, count: 256)
        var double: [UInt16] = []
        var quad: [UInt16] = []
        var longestCharacter = 1
    }

    /// The system's converter for one code page, asked one character at a time.
    private struct Converter {
        let encoding: CFStringEncoding

        /// The character that `bytes` are, as one UTF-16 unit; nil when they are not exactly one
        /// such character.
        func character(_ bytes: [UInt8]) -> UInt16? {
            guard let text = CFStringCreateWithBytes(nil, bytes, bytes.count, encoding, false),
                CFStringGetLength(text) == 1
            else { return nil }
            return CFStringGetCharacterAtIndex(text, 0)
        }
    }

    /// The mark in `single` of the first byte of a character of more than one byte.
    internal static let leadByte: UInt16 = 0xFFFF
    /// U+FFFD, what bytes that make no character become.
    internal static let replacement: UInt16 = 0xFFFD

    private static let lock = NSLock()
    /// Guarded by `lock`.
    nonisolated(unsafe) private static var tables: [Int: Self] = [:]

    /// The character of each byte; `leadByte` marks the first byte of a two-byte character.
    internal let single: [UInt16]
    /// The character of each two-byte sequence, at `lead << 8 | trail`; empty for one-byte pages.
    internal let double: [UInt16]
    /// GB 18030: the character of each four-byte sequence of the Basic Multilingual Plane, at
    /// `((b1 - 0x81) * 10 + b2 - 0x30) * 1260 + (b3 - 0x81) * 10 + b4 - 0x30` (b1 up to 0x84).
    internal let quad: [UInt16]
    /// How the bytes of a character are laid out.
    internal let shape: ViewerEncoding.Shape
    /// Bytes of the longest character.
    internal let longestCharacter: Int

    private init(_ encoding: ViewerEncoding) {
        let converter = Converter(
            encoding: encoding.coreFoundationEncoding ?? CFStringBuiltInEncodings.windowsLatin1.rawValue
        )
        shape = encoding.shape
        let built: Tables
        switch encoding.shape {
        case .doubleByte:
            built = Self.doubleByteTables(converter, isDouble: encoding.kind == .doubleByte)

        case .eucJP:
            built = Self.eucJPTables(converter)

        case .gb18030:
            built = Self.gb18030Tables(converter)
        }
        single = built.single
        double = built.double
        quad = built.quad
        longestCharacter = built.longestCharacter
    }

    /// The tables of `encoding`, built the first time they are asked for (on any thread).
    internal static func table(for encoding: ViewerEncoding) -> Self {
        lock.lock()
        defer { lock.unlock() }
        guard let table = tables[encoding.codePage] else {
            let table = Self(encoding)
            tables[encoding.codePage] = table
            return table
        }
        return table
    }

    /// A code page of one byte a character, or of a lead byte and a trail byte from 0x40 on.
    private static func doubleByteTables(_ converter: Converter, isDouble: Bool) -> Tables {
        var built = Tables()
        built.longestCharacter = isDouble ? 2 : 1
        if isDouble { built.double = [UInt16](repeating: replacement, count: 65_536) }
        for byte in 0..<256 {
            if byte < 0x80 {
                built.single[byte] = UInt16(byte)
            } else if let unit = converter.character([UInt8(byte)]) {
                built.single[byte] = unit
            } else if isDouble, (0x81...0xFE).contains(byte) {
                built.single[byte] = leadByte
                for trail in 0x40...0xFE {
                    if let unit = converter.character([UInt8(byte), UInt8(trail)]) {
                        built.double[byte << 8 | trail] = unit
                    }
                }
            }
        }
        return built
    }

    /// EUC-JP.
    ///
    /// The system's converter has the pairs (JIS X 0208 and the half-width katakana behind 0x8E)
    /// but none of the three-byte characters of JIS X 0212: those are one replacement each.
    private static func eucJPTables(_ converter: Converter) -> Tables {
        var built = Tables()
        built.longestCharacter = 3
        built.double = [UInt16](repeating: replacement, count: 65_536)
        for byte in 0..<0x80 { built.single[byte] = UInt16(byte) }
        for trail in 0xA1...0xDF {
            if let unit = converter.character([0x8E, UInt8(trail)]) { built.double[0x8E << 8 | trail] = unit }
        }
        for lead in 0xA1...0xFE {
            for trail in 0xA1...0xFE {
                if let unit = converter.character([UInt8(lead), UInt8(trail)]) {
                    built.double[lead << 8 | trail] = unit
                }
            }
        }
        return built
    }

    /// GB 18030: the pairs, and the four-byte characters of the Basic Multilingual Plane.
    private static func gb18030Tables(_ converter: Converter) -> Tables {
        var built = Tables()
        built.longestCharacter = 4
        built.double = [UInt16](repeating: replacement, count: 65_536)
        for byte in 0..<0x80 { built.single[byte] = UInt16(byte) }
        if let unit = converter.character([0x80]) { built.single[0x80] = unit }
        for lead in 0x81...0xFE {
            built.single[lead] = leadByte
            for trail in 0x40...0xFE where trail != 0x7F {
                if let unit = converter.character([UInt8(lead), UInt8(trail)]) {
                    built.double[lead << 8 | trail] = unit
                }
            }
        }
        built.quad = [UInt16](repeating: replacement, count: 4 * 10 * 1_260)
        for first in 0..<4 {
            for second in 0..<10 {
                for third in 0..<126 {
                    for fourth in 0..<10 {
                        let bytes = [
                            UInt8(0x81 + first), UInt8(0x30 + second), UInt8(0x81 + third), UInt8(0x30 + fourth)
                        ]
                        if let unit = converter.character(bytes) {
                            built.quad[(first * 10 + second) * 1_260 + third * 10 + fourth] = unit
                        }
                    }
                }
            }
        }
        return built
    }

    /// `1 + count` when the `count` bytes after `index` are each in `range`; 1 when one of them
    /// is not (the byte at `index` is a stray one); 0 when the bytes end before.
    @inline(__always)
    private static func length(
        _ bytes: UnsafeBufferPointer<UInt8>,
        at index: Int,
        trailing count: Int,
        in range: ClosedRange<UInt8>
    ) -> Int {
        for step in 1...count {
            guard index + step < bytes.count else {
                return 0
            }
            guard range.contains(bytes[index + step]) else {
                return 1
            }
        }
        return count + 1
    }

    /// How many bytes the character at `index` takes, by the layout of the code page alone:
    /// 1 for a byte that stands by itself or that cannot begin a character it is part of (a
    /// stray byte, which the decoder turns into a replacement character); 0 when the bytes
    /// there are too few to tell (the end of what was given).
    internal func characterLength(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Int {
        let byte = bytes[index]
        if byte < 0x80 {
            return 1
        }
        switch shape {
        case .doubleByte:
            guard single[Int(byte)] == Self.leadByte else {
                return 1
            }
            // A lead byte before something that cannot be a trail byte (a line end, a digit) is a stray byte.
            return Self.length(bytes, at: index, trailing: 1, in: 0x40...0xFF)

        case .eucJP:
            switch byte {
            case 0x8E:
                return Self.length(bytes, at: index, trailing: 1, in: 0xA1...0xDF)

            case 0x8F:
                return Self.length(bytes, at: index, trailing: 2, in: 0xA1...0xFE)

            case 0xA1...0xFE:
                return Self.length(bytes, at: index, trailing: 1, in: 0xA1...0xFE)

            default:
                return 1
            }

        case .gb18030:
            return gb18030Length(bytes, at: index)
        }
    }

    /// Whether `byte` is a character of its own whatever bytes are around it: the character after
    /// it begins right behind it.
    ///
    /// In a layout where the trail bytes are lead bytes too (EUC-JP) and where they run into the
    /// ASCII range (GB 18030) that is a smaller set than "not a lead byte".
    internal func isSynchronizing(_ byte: UInt8) -> Bool {
        switch shape {
        case .doubleByte:
            return single[Int(byte)] != Self.leadByte

        case .eucJP:
            return byte < 0x80

        case .gb18030:
            return byte < 0x30 || (0x3A...0x3F).contains(byte) || byte == 0x7F
        }
    }

    /// `characterLength` for GB 18030 and a byte from 0x80 on.
    private func gb18030Length(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Int {
        let count = bytes.count
        guard (0x81...0xFE).contains(bytes[index]) else {
            return 1
        }
        guard index + 1 < count else {
            return 0
        }
        let second = bytes[index + 1]
        if (0x40...0xFE).contains(second), second != 0x7F {
            return 2
        }
        guard (0x30...0x39).contains(second) else {
            return 1
        }
        guard index + 2 < count else {
            return 0
        }
        guard (0x81...0xFE).contains(bytes[index + 2]) else {
            return 1
        }
        guard index + 3 < count else {
            return 0
        }
        guard (0x30...0x39).contains(bytes[index + 3]) else {
            return 1
        }
        return 4
    }
}
