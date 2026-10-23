import Foundation

/// The encodings "Find text" can look for a text in (spec 09 › "Find text").
///
/// The Windows pair "ANSI" and "ASCII (DOS)" is kept for files that come from there; UTF-8 is what
/// a Mac writes and therefore the default. Stored by its raw value in saved searches.
public enum TextEncoding: String, Codable, CaseIterable, Sendable {
    /// "ASCII (DOS)": code page 437.
    case dos = "dos"
    /// "Unicode UTF-16", in either byte order.
    case utf16 = "utf16"
    /// "UTF-8".
    case utf8 = "utf8"
    /// "Western (Windows ANSI)": code page 1252.
    case western = "western"

    /// The encodings in the order of their boxes in the window.
    public static let allCases: [Self] = [.utf8, .western, .dos, .utf16]

    /// The title of the encoding's box.
    public var title: String {
        switch self {
        case .utf8:
            return "UTF-8"

        case .western:
            return "Western (Windows ANSI)"

        case .dos:
            return "ASCII (DOS)"

        case .utf16:
            return "Unicode UTF-16"
        }
    }

    /// The encoding of 8-bit text; UTF-16 is handled in both byte orders by the pattern.
    internal var stringEncoding: String.Encoding {
        switch self {
        case .utf8:
            return .utf8

        case .western:
            return .windowsCP1252

        case .dos:
            return String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)
                )
            )

        case .utf16:
            return .utf16LittleEndian
        }
    }
}
