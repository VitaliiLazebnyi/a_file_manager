import Foundation

/// A character encoding the viewer can show text in, named by its Windows code page number as
/// in the specification's Encoding menu (spec 10 › Encoding menu). A value type without state;
/// the conversion tables behind it are built once and shared (`CodeTable`).
struct ViewerEncoding: Hashable {
    enum Kind {
        case utf8, utf16LE, utf16BE
        /// One byte per character (the Windows, DOS and Mac code pages).
        case singleByte
        /// More than one byte per character (Japanese, Chinese, Korean code pages): one or two bytes,
        /// or, in EUC-JP and GB 18030, up to three and four (`shape` tells which).
        case doubleByte
    }

    /// How the bytes of a character are laid out in a code page of more than one byte.
    enum Shape {
        /// A byte below 0x80 or a lead byte and the byte after it, from 0x40 on (932, 936, 949, 950).
        case doubleByte
        /// EUC-JP: ASCII; 0x8E and a katakana byte; 0x8F and two bytes (JIS X 0212); two bytes from 0xA1.
        case eucJP
        /// GB 18030: ASCII; two bytes (lead 0x81…0xFE, trail 0x40…0xFE but 0x7F); four bytes
        /// (0x81…0xFE, 0x30…0x39, 0x81…0xFE, 0x30…0x39).
        case gb18030
    }

    let codePage: Int
    let name: String

    static let utf8 = Self(codePage: 65_001, name: "UTF-8")
    static let utf16LE = Self(codePage: 1_200, name: "UTF-16 LE")
    static let utf16BE = Self(codePage: 1_201, name: "UTF-16 BE")
    /// What the specification calls ANSI: the Windows code page of Western Europe.
    static let ansi = Self(codePage: 1_252, name: "ANSI / Western Latin 1 (1252)")
    /// What the specification calls ASCII: the DOS code page with the box-drawing characters.
    static let dos = Self(codePage: 437, name: "ASCII / DOS-USA (437)")
    static let latin1 = Self(codePage: 28_591, name: "ISO Latin 1 (8859-1)")
    static let macRoman = Self(codePage: 10_000, name: "Mac OS Roman (10000)")

    private static let multiBytePages: Set<Int> = [932, 936, 949, 950, 51_932, 54_936]

    /// The code pages of the specification's Encoding menu, as far as this Mac can convert them.
    static let codePages: [Self] = [
        ansi, dos, macRoman, latin1,
        Self(codePage: 1_250, name: "Eastern Europe (1250)"),
        Self(codePage: 1_251, name: "Cyrillic Windows (1251)"),
        Self(codePage: 1_253, name: "Greek (1253)"), Self(codePage: 1_254, name: "Turkish (1254)"),
        Self(codePage: 1_255, name: "Hebrew (1255)"), Self(codePage: 1_256, name: "Arabic (1256)"),
        Self(codePage: 1_257, name: "Baltic (1257)"),
        Self(codePage: 1_258, name: "Vietnamese (1258)"),
        Self(codePage: 936, name: "Chinese Main Land (936)"),
        Self(codePage: 950, name: "Chinese Taiwan (950)"),
        Self(codePage: 932, name: "Japanese (932)"), Self(codePage: 949, name: "Korean (949)"),
        Self(codePage: 51_932, name: "Japanese EUC (51932)"),
        Self(codePage: 54_936, name: "Chinese GB 18030 (54936)"),
        Self(codePage: 874, name: "Thai (874)"), Self(codePage: 850, name: "DOS-LATIN1 (850)"),
        Self(codePage: 866, name: "Cyrillic DOS (866)"),
        Self(codePage: 20_866, name: "Cyrillic KOI8-R (20866)")
    ]
    .filter(\.isAvailable)

    /// Any code page the system knows, for "Other (enter code page manually)"; nil otherwise.
    static func codePage(_ number: Int) -> Self? {
        if let known = ([utf8, utf16LE, utf16BE] + codePages).first(where: { $0.codePage == number }) { return known }
        let encoding = Self(codePage: number, name: "Code page \(number)")
        return encoding.isAvailable ? encoding : nil
    }

    var kind: Kind {
        switch codePage {
        case 65_001: return .utf8
        case 1_200: return .utf16LE
        case 1_201: return .utf16BE
        default: return Self.multiBytePages.contains(codePage) ? .doubleByte : .singleByte
        }
    }

    /// The layout of a character's bytes; `.doubleByte` for everything that is not EUC-JP or GB 18030.
    var shape: Shape {
        switch codePage {
        case 51_932: return .eucJP
        case 54_936: return .gb18030
        default: return .doubleByte
        }
    }

    /// Bytes per code unit: line ends and chunk borders fall on multiples of it.
    var unitSize: Int { kind == .utf16LE || kind == .utf16BE ? 2 : 1 }

    var isUnicode: Bool { kind == .utf8 || kind == .utf16LE || kind == .utf16BE }

    /// The encoding the byte-oriented modes (binary, hex) show characters in: this one when
    /// every byte is a character, else ANSI.
    var byteOriented: Self { kind == .singleByte ? self : .ansi }

    /// The encoding a layout really shows this one in.
    func forLayout(_ layout: ViewerLayout) -> Self {
        if case .text = layout { return self }
        return byteOriented
    }

    fileprivate var coreFoundationEncoding: CFStringEncoding? {
        guard codePage > 0, codePage <= Int(UInt32.max) else { return nil }
        let encoding = CFStringConvertWindowsCodepageToEncoding(UInt32(codePage))
        guard encoding != kCFStringEncodingInvalidId, CFStringIsEncodingAvailable(encoding) else {
            return nil
        }
        return encoding
    }

    /// Whether the system converts this code page, and the viewer can decode it: a code page of
    /// more than one byte a character is decoded here only for the six it knows the layout of
    /// (932, 936, 949, 950, EUC-JP 51932 and GB 18030 54936); the others (ISO-2022…) would show
    /// every byte above 0x7F as a replacement character, so they are not offered.
    var isAvailable: Bool {
        if isUnicode { return true }
        guard let encoding = coreFoundationEncoding else { return false }
        return Self.multiBytePages.contains(codePage) || CFStringGetMaximumSizeForEncoding(1, encoding) <= 1
    }

    /// The bytes of `text` in this encoding (for a search pattern); nil when it has characters
    /// the encoding lacks.
    func encode(_ text: String) -> [UInt8]? {
        switch kind {
        case .utf8: return Array(text.utf8)
        case .utf16LE: return text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        case .utf16BE: return text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }

        case .singleByte, .doubleByte:
            guard let encoding = coreFoundationEncoding else { return nil }
            return text.data(using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding)))
                .map(
                    Array.init
                )
        }
    }
}

/// Decoded text with, for every UTF-16 unit, the position of the byte it came from. The
/// positions are what let a place in the shown text be found in the file again (selection,
/// search results, the row index).
struct DecodedText {
    var units: [UInt16] = []
    /// Byte offset of each unit, counted from the start of the decoded bytes. The two halves of
    /// a surrogate pair share one offset.
    var offsets: [Int32] = []
    /// Off for callers that only want the text (copying, HTML): `offsets` then stays empty and
    /// nothing is spent on it.
    var tracksOffsets = true

    var string: String { String(decoding: units, as: UTF16.self) }

    mutating func removeAll() {
        units.removeAll(keepingCapacity: true)
        offsets.removeAll(keepingCapacity: true)
    }

    @inline(__always) fileprivate mutating func append(_ unit: UInt16, _ offset: Int) {
        units.append(unit)
        if tracksOffsets { offsets.append(Int32(truncatingIfNeeded: offset)) }
    }
}

/// The conversion tables of a code page, built once from the system's converter. Immutable
/// after creation, so every thread may read them.
final class CodeTable: Sendable {
    static let leadByte: UInt16 = 0xFFFF
    static let replacement: UInt16 = 0xFFFD

    /// The character of each byte; `leadByte` marks the first byte of a two-byte character.
    let single: [UInt16]
    /// The character of each two-byte sequence, at `lead << 8 | trail`; empty for one-byte pages.
    let double: [UInt16]
    /// GB 18030: the character of each four-byte sequence of the Basic Multilingual Plane, at
    /// `((b1 - 0x81) * 10 + b2 - 0x30) * 1260 + (b3 - 0x81) * 10 + b4 - 0x30` (b1 up to 0x84).
    let quad: [UInt16]
    let shape: ViewerEncoding.Shape
    /// Bytes of the longest character.
    let longestCharacter: Int

    private static let lock = NSLock()
    /// Guarded by `lock`.
    nonisolated(unsafe) private static var tables: [Int: CodeTable] = [:]

    static func table(for encoding: ViewerEncoding) -> CodeTable {
        lock.lock()
        defer { lock.unlock() }
        guard let table = tables[encoding.codePage] else {
            let table = CodeTable(encoding)
            tables[encoding.codePage] = table
            return table
        }
        return table
    }

    private init(_ encoding: ViewerEncoding) {
        let cfEncoding = encoding.coreFoundationEncoding ?? CFStringBuiltInEncodings.windowsLatin1.rawValue
        func convert(_ bytes: [UInt8]) -> UInt16? {
            guard let text = CFStringCreateWithBytes(nil, bytes, bytes.count, cfEncoding, false),
                CFStringGetLength(text) == 1
            else { return nil }
            return CFStringGetCharacterAtIndex(text, 0)
        }
        let isDouble = encoding.kind == .doubleByte
        let shape = encoding.shape
        self.shape = shape
        var single = [UInt16](repeating: Self.replacement, count: 256)
        var double: [UInt16] = isDouble ? [UInt16](repeating: Self.replacement, count: 65_536) : []
        var quad: [UInt16] = []
        switch shape {
        case .doubleByte:
            longestCharacter = isDouble ? 2 : 1
            for byte in 0..<256 {
                if byte < 0x80 {
                    single[byte] = UInt16(byte)
                } else if let unit = convert([UInt8(byte)]) {
                    single[byte] = unit
                } else if isDouble, (0x81...0xFE).contains(byte) {
                    single[byte] = Self.leadByte
                    for trail in 0x40...0xFE {
                        if let unit = convert([UInt8(byte), UInt8(trail)]) { double[byte << 8 | trail] = unit }
                    }
                }
            }

        case .eucJP:
            longestCharacter = 3
            for byte in 0..<0x80 { single[byte] = UInt16(byte) }
            // The system's converter has the pairs (JIS X 0208 and the half-width katakana behind 0x8E)
            // but none of the three-byte characters of JIS X 0212: those are one replacement each.
            for trail in 0xA1...0xDF {
                if let unit = convert([0x8E, UInt8(trail)]) { double[0x8E << 8 | trail] = unit }
            }
            for lead in 0xA1...0xFE {
                for trail in 0xA1...0xFE {
                    if let unit = convert([UInt8(lead), UInt8(trail)]) { double[lead << 8 | trail] = unit }
                }
            }

        case .gb18030:
            longestCharacter = 4
            for byte in 0..<0x80 { single[byte] = UInt16(byte) }
            if let unit = convert([0x80]) { single[0x80] = unit }
            for lead in 0x81...0xFE {
                single[lead] = Self.leadByte
                for trail in 0x40...0xFE where trail != 0x7F {
                    if let unit = convert([UInt8(lead), UInt8(trail)]) { double[lead << 8 | trail] = unit }
                }
            }
            quad = [UInt16](repeating: Self.replacement, count: 4 * 10 * 1_260)
            for first in 0..<4 {
                for second in 0..<10 {
                    for third in 0..<126 {
                        for fourth in 0..<10 {
                            let bytes = [
                                UInt8(0x81 + first), UInt8(0x30 + second), UInt8(0x81 + third), UInt8(0x30 + fourth)
                            ]
                            if let unit = convert(bytes) {
                                quad[(first * 10 + second) * 1_260 + third * 10 + fourth] = unit
                            }
                        }
                    }
                }
            }
        }
        self.single = single
        self.double = double
        self.quad = quad
    }

    /// How many bytes the character at `index` takes, by the layout of the code page alone:
    /// 1 for a byte that stands by itself or that cannot begin a character it is part of (a
    /// stray byte, which the decoder turns into a replacement character); 0 when the bytes
    /// there are too few to tell (the end of what was given).
    func characterLength(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Int {
        let count = bytes.count
        let byte = bytes[index]
        if byte < 0x80 { return 1 }
        switch shape {
        case .doubleByte:
            guard single[Int(byte)] == Self.leadByte else { return 1 }
            // A lead byte before something that cannot be a trail byte (a line end, a digit) is a stray byte.
            guard index + 1 < count else { return 0 }
            guard bytes[index + 1] >= 0x40 else {
                return 1
            }
            return 2

        case .eucJP:
            switch byte {
            case 0x8E:
                guard index + 1 < count else { return 0 }
                guard (0xA1...0xDF).contains(bytes[index + 1]) else {
                    return 1
                }
                return 2

            case 0x8F:
                guard index + 1 < count else { return 0 }
                guard (0xA1...0xFE).contains(bytes[index + 1]) else { return 1 }
                guard index + 2 < count else { return 0 }
                guard (0xA1...0xFE).contains(bytes[index + 2]) else {
                    return 1
                }
                return 3

            case 0xA1...0xFE:
                guard index + 1 < count else { return 0 }
                guard (0xA1...0xFE).contains(bytes[index + 1]) else {
                    return 1
                }
                return 2

            default:
                return 1
            }

        case .gb18030:
            guard (0x81...0xFE).contains(byte) else { return 1 }
            guard index + 1 < count else { return 0 }
            let second = bytes[index + 1]
            if (0x40...0xFE).contains(second), second != 0x7F { return 2 }
            guard (0x30...0x39).contains(second) else { return 1 }
            guard index + 2 < count else { return 0 }
            guard (0x81...0xFE).contains(bytes[index + 2]) else { return 1 }
            guard index + 3 < count else { return 0 }
            guard (0x30...0x39).contains(bytes[index + 3]) else {
                return 1
            }
            return 4
        }
    }

    /// Whether `byte` is a character of its own whatever bytes are around it: the character after
    /// it begins right behind it. In a layout where the trail bytes are lead bytes too (EUC-JP) and
    /// where they run into the ASCII range (GB 18030) that is a smaller set than "not a lead byte".
    func isSynchronizing(_ byte: UInt8) -> Bool {
        switch shape {
        case .doubleByte: return single[Int(byte)] != Self.leadByte
        case .eucJP: return byte < 0x80
        case .gb18030: return byte < 0x30 || (0x3A...0x3F).contains(byte) || byte == 0x7F
        }
    }
}

extension ViewerEncoding {
    /// Decodes `bytes` into `text` (replacing what it held) and returns how many bytes were
    /// used. Unless `final`, a character cut off at the end is left for the next call, when the
    /// rest of it has arrived: this is how text is decoded block by block. Malformed input
    /// becomes U+FFFD, one per offending byte, and never stops the decoding.
    @discardableResult
    func decode(_ bytes: UnsafeBufferPointer<UInt8>, final: Bool, into text: inout DecodedText) -> Int {
        text.removeAll()
        text.units.reserveCapacity(bytes.count / unitSize + 1)
        if text.tracksOffsets { text.offsets.reserveCapacity(bytes.count / unitSize + 1) }
        switch kind {
        case .utf8: return Self.decodeUTF8(bytes, final, &text)
        case .utf16LE: return Self.decodeUTF16(bytes, final, littleEndian: true, &text)
        case .utf16BE: return Self.decodeUTF16(bytes, final, littleEndian: false, &text)

        case .singleByte, .doubleByte:
            let table = CodeTable.table(for: self)
            return table.shape == .doubleByte
                ? Self.decodeTable(bytes, final, table, &text)
                : Self.decodeLayout(bytes, final, table, &text)
        }
    }

    @discardableResult
    func decode(_ data: Data, final: Bool, into text: inout DecodedText) -> Int {
        data.withUnsafeBytes { raw in decode(raw.bindMemory(to: UInt8.self), final: final, into: &text) }
    }

    @discardableResult
    func decode(_ bytes: [UInt8], final: Bool, into text: inout DecodedText) -> Int {
        bytes.withUnsafeBufferPointer { decode($0, final: final, into: &text) }
    }

    /// The whole of `data` as text.
    func string(from data: Data) -> String {
        var text = DecodedText()
        text.tracksOffsets = false
        decode(data, final: true, into: &text)
        return text.string
    }

    /// The whole of `data` as UTF-16 units, without the byte offsets.
    func units(from data: Data) -> [UInt16] {
        var text = DecodedText()
        text.tracksOffsets = false
        decode(data, final: true, into: &text)
        return text.units
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

    private static func decodeUTF8(_ bytes: UnsafeBufferPointer<UInt8>, _ final: Bool, _ text: inout DecodedText) -> Int
    {
        let count = bytes.count
        var index = 0
        while index < count {
            let lead = bytes[index]
            if lead < 0x80 {
                text.append(UInt16(lead), index)
                index += 1
                continue
            }
            // How many bytes follow, and the range the first of them must be in (this is what
            // rules out overlong forms, surrogates and values beyond U+10FFFF).
            let following: Int
            let first: ClosedRange<UInt8>
            switch lead {
            case 0xC2...0xDF: (following, first) = (1, 0x80...0xBF)
            case 0xE0: (following, first) = (2, 0xA0...0xBF)
            case 0xED: (following, first) = (2, 0x80...0x9F)
            case 0xE1...0xEF: (following, first) = (2, 0x80...0xBF)
            case 0xF0: (following, first) = (3, 0x90...0xBF)
            case 0xF4: (following, first) = (3, 0x80...0x8F)
            case 0xF1...0xF3: (following, first) = (3, 0x80...0xBF)
            default: (following, first) = (0, 0x80...0xBF)
            }
            var valid = following > 0
            var scalar = UInt32(lead) & (following == 1 ? 0x1F : following == 2 ? 0x0F : 0x07)
            var incomplete = false
            if valid {
                for step in 1...following {
                    guard index + step < count else {
                        incomplete = true
                        break
                    }
                    let byte = bytes[index + step]
                    guard step == 1 ? first.contains(byte) : (0x80...0xBF).contains(byte) else {
                        valid = false
                        break
                    }
                    scalar = scalar << 6 | UInt32(byte & 0x3F)
                }
            }
            if valid, incomplete {
                if !final { break }
                valid = false
            }
            if !valid {
                text.append(CodeTable.replacement, index)
                index += 1
            } else if scalar < 0x10000 {
                text.append(UInt16(scalar), index)
                index += following + 1
            } else {
                let value = scalar - 0x10000
                text.append(UInt16(0xD800 + (value >> 10)), index)
                text.append(UInt16(0xDC00 + (value & 0x3FF)), index)
                index += following + 1
            }
        }
        return index
    }

    private static func decodeUTF16(
        _ bytes: UnsafeBufferPointer<UInt8>,
        _ final: Bool,
        littleEndian: Bool,
        _ text: inout DecodedText
    ) -> Int {
        let count = bytes.count
        @inline(__always) func unit(_ at: Int) -> UInt16 {
            littleEndian
                ? UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 : UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
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
}
