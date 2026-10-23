import Foundation

/// How bytes in an encoding become text.
extension ViewerEncoding {
    /// What the bytes at a place of UTF-8 text are.
    private enum UTF8Character {
        /// A character of `length` bytes (2 to 4).
        case scalar(UInt32, length: Int)
        /// A byte that begins no character, or a sequence broken off by a wrong byte.
        case invalid
        /// A sequence that is right as far as it goes, but the bytes end before it does.
        case incomplete
    }

    private static func decodeTable(
        _ bytes: UnsafeBufferPointer<UInt8>,
        _ final: Bool,
        _ table: CodeTable,
        _ text: inout DecodedText
    ) -> Int {
        let count = bytes.count
        return table.single.withUnsafeBufferPointer { single in
            table.double.withUnsafeBufferPointer { double in
                var index = 0
                while index < count {
                    let byte = Int(bytes[index])
                    let unit = single[byte]
                    if unit != CodeTable.leadByte {
                        text.append(unit, index)
                        index += 1
                    } else if index + 1 < count {
                        let trail = Int(bytes[index + 1])
                        // A lead byte before something that cannot be a trail byte (a line end,
                        // a digit) is a stray byte; the next byte keeps its own meaning.
                        if trail < 0x40 {
                            text.append(CodeTable.replacement, index)
                            index += 1
                        } else {
                            text.append(double[byte << 8 | trail], index)
                            index += 2
                        }
                    } else if final {
                        text.append(CodeTable.replacement, index)
                        index += 1
                    } else {
                        break
                    }
                }
                return index
            }
        }
    }

    /// EUC-JP and GB 18030: the length of each character comes from the layout (`characterLength`).
    private static func decodeLayout(
        _ bytes: UnsafeBufferPointer<UInt8>,
        _ final: Bool,
        _ table: CodeTable,
        _ text: inout DecodedText
    ) -> Int {
        let count = bytes.count
        var index = 0
        while index < count {
            let byte = Int(bytes[index])
            if byte < 0x80 {
                text.append(UInt16(byte), index)
                index += 1
                continue
            }
            let length = table.characterLength(bytes, at: index)
            if length == 0 {
                // A character cut off at the end: left for the next call, unless this is the end.
                if !final { break }
                text.append(CodeTable.replacement, index)
                index += 1
                continue
            }
            switch length {
            case 1:
                let unit = table.single[byte]
                text.append(unit == CodeTable.leadByte ? CodeTable.replacement : unit, index)

            case 2:
                text.append(table.double[byte << 8 | Int(bytes[index + 1])], index)

            case 3:
                text.append(CodeTable.replacement, index)

            default:
                let first = byte - 0x81
                let second = Int(bytes[index + 1]) - 0x30
                let third = Int(bytes[index + 2]) - 0x81
                let fourth = Int(bytes[index + 3]) - 0x30
                // Beyond the Basic Multilingual Plane the numbering is straight: 0x90308130 is U+10000.
                let scalar = 0x10000 + (((first - (0x90 - 0x81)) * 10 + second) * 126 + third) * 10 + fourth
                if first < 4 {
                    text.append(table.quad[(first * 10 + second) * 1_260 + third * 10 + fourth], index)
                } else if first < 0x90 - 0x81 || scalar > 0x10FFFF {
                    // Between the two ranges, and past the last character, nothing is assigned.
                    text.append(CodeTable.replacement, index)
                } else {
                    text.append(UInt16(0xD800 + ((scalar - 0x10000) >> 10)), index)
                    text.append(UInt16(0xDC00 + ((scalar - 0x10000) & 0x3FF)), index)
                }
            }
            index += length
        }
        return index
    }

    private static func decodeUTF8(
        _ bytes: UnsafeBufferPointer<UInt8>,
        _ final: Bool,
        _ text: inout DecodedText
    ) -> Int {
        let count = bytes.count
        var index = 0
        while index < count {
            let lead = bytes[index]
            if lead < 0x80 {
                text.append(UInt16(lead), index)
                index += 1
                continue
            }
            switch utf8Character(bytes, at: index) {
            case .scalar(let scalar, let length) where scalar < 0x10000:
                text.append(UInt16(scalar), index)
                index += length

            case .scalar(let scalar, let length):
                let value = scalar - 0x10000
                text.append(UInt16(0xD800 + (value >> 10)), index)
                text.append(UInt16(0xDC00 + (value & 0x3FF)), index)
                index += length

            case .incomplete where !final:
                // Left for the next call, when the rest of it has arrived.
                return index

            case .invalid, .incomplete:
                text.append(CodeTable.replacement, index)
                index += 1
            }
        }
        return index
    }

    /// The character whose lead byte (0x80 or more) is at `index`.
    @inline(__always)
    private static func utf8Character(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> UTF8Character {
        let lead = bytes[index]
        let (following, first) = utf8Layout(lead)
        guard following > 0 else {
            return .invalid
        }
        var scalar = UInt32(lead) & (following == 1 ? 0x1F : following == 2 ? 0x0F : 0x07)
        for step in 1...following {
            guard index + step < bytes.count else {
                return .incomplete
            }
            let byte = bytes[index + step]
            guard step == 1 ? first.contains(byte) : (0x80...0xBF).contains(byte) else {
                return .invalid
            }
            scalar = scalar << 6 | UInt32(byte & 0x3F)
        }
        return .scalar(scalar, length: following + 1)
    }

    /// How many bytes follow the lead byte `lead`, and the range the first of them must be in
    /// (this is what rules out overlong forms, surrogates and values beyond U+10FFFF); 0 bytes
    /// for a byte that begins no character.
    @inline(__always)
    private static func utf8Layout(_ lead: UInt8) -> (following: Int, first: ClosedRange<UInt8>) {
        switch lead {
        case 0xC2...0xDF:
            return (1, 0x80...0xBF)

        case 0xE0:
            return (2, 0xA0...0xBF)

        case 0xED:
            return (2, 0x80...0x9F)

        case 0xE1...0xEF:
            return (2, 0x80...0xBF)

        case 0xF0:
            return (3, 0x90...0xBF)

        case 0xF4:
            return (3, 0x80...0x8F)

        case 0xF1...0xF3:
            return (3, 0x80...0xBF)

        default:
            return (0, 0x80...0xBF)
        }
    }

    private static func decodeUTF16(
        _ bytes: UnsafeBufferPointer<UInt8>,
        _ final: Bool,
        littleEndian: Bool,
        _ text: inout DecodedText
    ) -> Int {
        let count = bytes.count
        @inline(__always)
        func unit(_ position: Int) -> UInt16 {
            littleEndian
                ? UInt16(bytes[position]) | UInt16(bytes[position + 1]) << 8
                : UInt16(bytes[position]) << 8 | UInt16(bytes[position + 1])
        }
        var index = 0
        while index < count {
            guard index + 1 < count else {
                if !final { break }
                text.append(CodeTable.replacement, index)
                index += 1
                break
            }
            let value = unit(index)
            if (0xD800...0xDBFF).contains(value) {
                // A high surrogate cut off at the end is left for the next call, unless this is the end.
                if index + 3 >= count, !final { break }
                let low = index + 3 >= count ? 0 : unit(index + 2)
                if !(0xDC00...0xDFFF).contains(low) {
                    // A high surrogate without its low one.
                    text.append(CodeTable.replacement, index)
                    index += 2
                    continue
                }
                text.append(value, index)
                text.append(low, index)
                index += 4
                continue
            }
            if (0xDC00...0xDFFF).contains(value) {
                text.append(CodeTable.replacement, index)
            } else {
                text.append(value, index)
            }
            index += 2
        }
        return index
    }

    /// Decodes `bytes` into `text` (replacing what it held) and returns how many bytes were
    /// used.
    ///
    /// Unless `final`, a character cut off at the end is left for the next call, when the rest of
    /// it has arrived: this is how text is decoded block by block. Malformed input becomes U+FFFD,
    /// one per offending byte, and never stops the decoding.
    @discardableResult
    internal func decode(_ bytes: UnsafeBufferPointer<UInt8>, final: Bool, into text: inout DecodedText) -> Int {
        text.removeAll()
        text.units.reserveCapacity(bytes.count / unitSize + 1)
        if text.tracksOffsets { text.offsets.reserveCapacity(bytes.count / unitSize + 1) }
        switch kind {
        case .utf8:
            return Self.decodeUTF8(bytes, final, &text)

        case .utf16LE:
            return Self.decodeUTF16(bytes, final, littleEndian: true, &text)

        case .utf16BE:
            return Self.decodeUTF16(bytes, final, littleEndian: false, &text)

        case .singleByte, .doubleByte:
            let table = CodeTable.table(for: self)
            return table.shape == .doubleByte
                ? Self.decodeTable(bytes, final, table, &text)
                : Self.decodeLayout(bytes, final, table, &text)
        }
    }

    /// `decode` for the bytes of `data`.
    @discardableResult
    internal func decode(_ data: Data, final: Bool, into text: inout DecodedText) -> Int {
        data.withUnsafeBytes { raw in decode(raw.bindMemory(to: UInt8.self), final: final, into: &text) }
    }

    /// `decode` for the bytes of an array.
    @discardableResult
    internal func decode(_ bytes: [UInt8], final: Bool, into text: inout DecodedText) -> Int {
        bytes.withUnsafeBufferPointer { buffer in decode(buffer, final: final, into: &text) }
    }

    /// The whole of `data` as text.
    internal func string(from data: Data) -> String {
        var text = DecodedText()
        text.tracksOffsets = false
        decode(data, final: true, into: &text)
        return text.string
    }

    /// The whole of `data` as UTF-16 units, without the byte offsets.
    internal func units(from data: Data) -> [UInt16] {
        var text = DecodedText()
        text.tracksOffsets = false
        decode(data, final: true, into: &text)
        return text.units
    }
}
