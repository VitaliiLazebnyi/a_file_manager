import Foundation

/// A character encoding the viewer can show text in, named by its Windows code page number as
/// in the specification's Encoding menu (spec 10 › Encoding menu).
///
/// A value type without state; the conversion tables behind it are built once and shared
/// (`CodeTable`).
internal struct ViewerEncoding: Hashable {
    /// How the bytes of an encoding become characters.
    internal enum Kind {
        /// UTF-8.
        case utf8
        /// UTF-16, low byte first.
        case utf16LE
        /// UTF-16, high byte first.
        case utf16BE
        /// One byte per character (the Windows, DOS and Mac code pages).
        case singleByte
        /// More than one byte per character (Japanese, Chinese, Korean code pages): one or two bytes,
        /// or, in EUC-JP and GB 18030, up to three and four (`shape` tells which).
        case doubleByte
    }

    /// How the bytes of a character are laid out in a code page of more than one byte.
    internal enum Shape {
        /// A byte below 0x80 or a lead byte and the byte after it, from 0x40 on (932, 936, 949, 950).
        case doubleByte
        /// EUC-JP: ASCII; 0x8E and a katakana byte; 0x8F and two bytes (JIS X 0212); two bytes from 0xA1.
        case eucJP
        /// GB 18030: ASCII; two bytes (lead 0x81…0xFE, trail 0x40…0xFE but 0x7F); four bytes
        /// (0x81…0xFE, 0x30…0x39, 0x81…0xFE, 0x30…0x39).
        case gb18030
    }

    /// UTF-8, code page 65001.
    internal static let utf8 = Self(codePage: 65_001, name: "UTF-8")
    /// UTF-16 with the low byte first, code page 1200.
    internal static let utf16LE = Self(codePage: 1_200, name: "UTF-16 LE")
    /// UTF-16 with the high byte first, code page 1201.
    internal static let utf16BE = Self(codePage: 1_201, name: "UTF-16 BE")
    /// What the specification calls ANSI: the Windows code page of Western Europe.
    internal static let ansi = Self(codePage: 1_252, name: "ANSI / Western Latin 1 (1252)")
    /// What the specification calls ASCII: the DOS code page with the box-drawing characters.
    internal static let dos = Self(codePage: 437, name: "ASCII / DOS-USA (437)")
    /// ISO 8859-1, code page 28591.
    internal static let latin1 = Self(codePage: 28_591, name: "ISO Latin 1 (8859-1)")
    /// The classic Mac code page, 10000.
    internal static let macRoman = Self(codePage: 10_000, name: "Mac OS Roman (10000)")

    private static let multiBytePages: Set<Int> = [932, 936, 949, 950, 51_932, 54_936]

    /// The code pages of the specification's Encoding menu, as far as this Mac can convert them.
    internal static let codePages: [Self] = [
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

    /// The Windows code page number that names the encoding.
    internal let codePage: Int
    /// The name the Encoding menu shows.
    internal let name: String

    /// How the bytes become characters, by the code page.
    internal var kind: Kind {
        switch codePage {
        case 65_001:
            return .utf8

        case 1_200:
            return .utf16LE

        case 1_201:
            return .utf16BE

        default:
            return Self.multiBytePages.contains(codePage) ? .doubleByte : .singleByte
        }
    }

    /// The layout of a character's bytes; `.doubleByte` for everything that is not EUC-JP or GB 18030.
    internal var shape: Shape {
        switch codePage {
        case 51_932:
            return .eucJP

        case 54_936:
            return .gb18030

        default:
            return .doubleByte
        }
    }

    /// Bytes per code unit: line ends and chunk borders fall on multiples of it.
    internal var unitSize: Int { kind == .utf16LE || kind == .utf16BE ? 2 : 1 }

    /// Whether this is UTF-8 or UTF-16.
    internal var isUnicode: Bool { kind == .utf8 || kind == .utf16LE || kind == .utf16BE }

    /// The encoding the byte-oriented modes (binary, hex) show characters in: this one when
    /// every byte is a character, else ANSI.
    internal var byteOriented: Self { kind == .singleByte ? self : .ansi }

    /// The system's encoding for the code page; nil when the system does not know or cannot
    /// convert it.
    internal var coreFoundationEncoding: CFStringEncoding? {
        guard codePage > 0, codePage <= Int(UInt32.max) else {
            return nil
        }
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
    internal var isAvailable: Bool {
        if isUnicode {
            return true
        }
        guard let encoding = coreFoundationEncoding else {
            return false
        }
        return Self.multiBytePages.contains(codePage) || CFStringGetMaximumSizeForEncoding(1, encoding) <= 1
    }

    /// Any code page the system knows, for "Other (enter code page manually)"; nil otherwise.
    internal static func codePage(_ number: Int) -> Self? {
        if let known = ([utf8, utf16LE, utf16BE] + codePages).first(where: { $0.codePage == number }) {
            return known
        }
        let encoding = Self(codePage: number, name: "Code page \(number)")
        return encoding.isAvailable ? encoding : nil
    }

    /// The encoding a layout really shows this one in.
    internal func forLayout(_ layout: ViewerLayout) -> Self {
        if case .text = layout {
            return self
        }
        return byteOriented
    }

    /// The bytes of `text` in this encoding (for a search pattern).
    ///
    /// Throws `CocoaError.fileWriteInapplicableStringEncoding` when it has characters the encoding
    /// lacks.
    internal func encode(_ text: String) throws -> [UInt8] {
        switch kind {
        case .utf8:
            return Array(text.utf8)

        case .utf16LE:
            return text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }

        case .utf16BE:
            return text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }

        case .singleByte, .doubleByte:
            guard let encoding = coreFoundationEncoding,
                let data = text.data(
                    using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
                )
            else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
            return Array(data)
        }
    }
}
