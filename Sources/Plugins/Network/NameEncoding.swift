import AFMKernel
internal import Foundation

/// How file names travel on the control connection (spec 11 › File-name encoding).
///
/// The raw values are stored with saved connections, and `allCases` is the order of the choice in the
/// connection dialog, whose index is the raw value.
public enum NameEncoding: Int, Codable, CaseIterable, Sendable {
    /// UTF-8 when the server offers it or the names are valid UTF-8, else Western Latin 1.
    case automatic = 0
    /// Big5, traditional Chinese (code page 950).
    case big5 = 11
    /// DOS for the United States (code page 437).
    case dosLatinUS = 8
    /// EUC-KR, Korean (code page 949).
    case eucKR = 12
    /// GB 18030, simplified Chinese (code page 936).
    case gb18030 = 10
    /// ISO 8859-1, Western Latin.
    case isoLatin1 = 3
    /// KOI8-R, Cyrillic.
    case koi8R = 6
    /// Mac OS Roman.
    case macRoman = 7
    /// Shift JIS, Japanese (code page 932).
    case shiftJIS = 9
    /// UTF-8 always.
    case utf8 = 1
    /// Windows Cyrillic (code page 1251).
    case windowsCyrillic = 5
    /// Windows Western Latin 1 (code page 1252).
    case windowsLatin1 = 2
    /// Windows Central European (code page 1250).
    case windowsLatin2 = 4

    /// Every choice in the order of the connection dialog, which is the order of the raw values.
    public static let allCases: [Self] = [
        .automatic, .utf8, .windowsLatin1, .isoLatin1, .windowsLatin2, .windowsCyrillic, .koi8R, .macRoman,
        .dosLatinUS, .shiftJIS, .gb18030, .big5, .eucKR
    ]

    /// The name of the choice in the connection dialog.
    public var title: String {
        switch self {
        case .automatic:
            return "Auto-Detect (UTF-8 if possible)"

        case .utf8:
            return "UTF-8"

        case .windowsLatin1:
            return "Western Latin1 (1252)"

        case .isoLatin1:
            return "Western ISO 8859-1"

        case .windowsLatin2:
            return "Eastern Europe (1250)"

        case .windowsCyrillic:
            return "Cyrillic Windows (1251)"

        case .koi8R:
            return "Cyrillic KOI8-R (20866)"

        case .macRoman:
            return "Mac Roman"

        case .dosLatinUS:
            return "DOS-USA (437)"

        case .shiftJIS:
            return "Japanese (932)"

        case .gb18030:
            return "Chinese Main Land (936)"

        case .big5:
            return "Chinese Taiwan (950)"

        case .eucKR:
            return "Korean (949)"
        }
    }

    /// The text encoding of the choice; nil for the automatic choice.
    internal var encoding: String.Encoding? {
        func named(_ encoding: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
        }
        switch self {
        case .automatic:
            return nil

        case .utf8:
            return .utf8

        case .windowsLatin1:
            return .windowsCP1252

        case .isoLatin1:
            return .isoLatin1

        case .windowsLatin2:
            return .windowsCP1250

        case .windowsCyrillic:
            return .windowsCP1251

        case .koi8R:
            return named(.KOI8_R)

        case .macRoman:
            return .macOSRoman

        case .dosLatinUS:
            return named(.dosLatinUS)

        case .shiftJIS:
            return .shiftJIS

        case .gb18030:
            return named(.GB_18030_2000)

        case .big5:
            return named(.big5)

        case .eucKR:
            return named(.EUC_KR)
        }
    }

    /// The encoding names are written in when nothing else is known of a name.
    internal var sending: String.Encoding { encoding ?? .utf8 }

    /// The text of bytes from the server (see `decodeTelling`).
    internal func decode(_ data: Data) -> String { decodeTelling(data).text }

    /// The text of bytes from the server, and the encoding that read them.
    ///
    /// In the automatic mode bytes that are not UTF-8 are read as Western Latin 1; `NameMemory`
    /// keeps that, so the name goes back to the server as the bytes it came as.
    internal func decodeTelling(_ data: Data) -> (text: String, encoding: String.Encoding) {
        for candidate in encoding.map({ [$0] }) ?? [.utf8, .windowsCP1252] {
            if let text = String(data: data, encoding: candidate) {
                return (text, candidate)
            }
        }
        // Bytes that no candidate reads are still shown: as UTF-8, with replacement characters.
        return (String(repairingUTF8: data), .utf8)
    }

    /// The bytes of a command.
    ///
    /// Names are sent the way the Mac writes them when composed (servers compare bytes), except the
    /// names the server itself spelled differently, which `names` remembers (nil: none). A character the
    /// encoding does not have is an error: written as `?` it would name another file.
    internal func encode(_ text: String, names: NameMemory?) throws -> Data {
        func bytes(_ piece: String, as encoding: String.Encoding) throws -> Data {
            guard let data = piece.data(using: encoding, allowLossyConversion: false) else {
                throw FileSystemError.notSupported(
                    "Writing the name \(piece) in the encoding of this server (\(title))"
                )
            }
            return data
        }
        guard let names, !names.isEmpty, text.utf8.contains(0x2F) else {
            return try bytes(text.precomposedStringWithCanonicalMapping, as: sending)
        }
        // A command with a path: the path is absolute, so everything after a slash is a name. Split by
        // scalars, as the bytes are: a slash followed by a combining mark is still a separator.
        var result = Data()
        for (index, piece) in text.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { result.append(0x2F) }
            let name = String(piece)
            if index > 0, let spelled = names.encoding(of: name.utf8) {
                result.append(try bytes(name, as: spelled))
            } else {
                result.append(try bytes(name.precomposedStringWithCanonicalMapping, as: sending))
            }
        }
        return result
    }
}
