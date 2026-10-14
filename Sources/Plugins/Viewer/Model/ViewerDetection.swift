import Foundation

/// What the start of a file says about how to show it (spec 10 › Choosing the mode at
/// start-up). The specification leaves the heuristics open ("a clone must choose its own");
/// these are the viewer's. Pure functions on a sample of the file.
enum ViewerDetection {
    /// How many bytes from the start of a file are looked at.
    static let sampleSize = 64 * 1_024

    struct TextGuess: Equatable {
        var encoding: ViewerEncoding
        /// The length of a byte-order mark at the start; it is not part of the text.
        var bomLength = 0
        /// The sample does not look like text in any encoding.
        var isBinary = false
    }

    /// A byte-order mark names the encoding outright.
    static func byteOrderMark(_ sample: Data) -> (encoding: ViewerEncoding, length: Int)? {
        let bytes = [UInt8](sample.prefix(3))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return (.utf8, 3) }
        if bytes.starts(with: [0xFF, 0xFE]) { return (.utf16LE, 2) }
        if bytes.starts(with: [0xFE, 0xFF]) { return (.utf16BE, 2) }
        return nil
    }

    /// Tells text from binary data and guesses the encoding of text. In order: a byte-order
    /// mark; UTF-16 without one (every other byte zero, as Latin text has it); binary data
    /// (NUL bytes, many control characters); valid UTF-8; and for the rest the choice between
    /// the Windows and the DOS code page. `isWholeFile` says that the sample is not cut off,
    /// so a UTF-8 sequence may not end in the middle.
    static func guessText(_ sample: Data, isWholeFile: Bool) -> TextGuess {
        if let mark = byteOrderMark(sample) { return TextGuess(encoding: mark.encoding, bomLength: mark.length) }
        let bytes = [UInt8](sample)
        guard !bytes.isEmpty else { return TextGuess(encoding: .utf8) }
        if let utf16 = guessUTF16(bytes) { return TextGuess(encoding: utf16) }
        if looksBinary(bytes) { return TextGuess(encoding: .ansi, isBinary: true) }
        switch utf8Validity(bytes, mayBeCutOff: !isWholeFile) {
        // Plain ASCII reads the same in every code page; on a Mac, what follows the sample is
        // most likely UTF-8.
        case .ascii, .multiByte: return TextGuess(encoding: .utf8)
        case .invalid: return TextGuess(encoding: looksLikeDOS(bytes) ? .dos : .ansi)
        }
    }

    /// UTF-16 without a mark: in text of mostly Latin letters one byte of each pair is zero,
    /// always on the same side.
    static func guessUTF16(_ bytes: [UInt8]) -> ViewerEncoding? {
        let pairs = bytes.count / 2
        guard pairs >= 2 else { return nil }
        var zeroEven = 0
        var zeroOdd = 0
        for pair in 0..<pairs {
            if bytes[pair * 2] == 0 { zeroEven += 1 }
            if bytes[pair * 2 + 1] == 0 { zeroOdd += 1 }
        }
        if zeroOdd * 10 >= pairs * 4, zeroEven * 20 <= pairs { return .utf16LE }
        if zeroEven * 10 >= pairs * 4, zeroOdd * 20 <= pairs { return .utf16BE }
        return nil
    }

    /// Binary: any NUL byte, or more than one control character in twenty that text has no
    /// use for.
    static func looksBinary(_ bytes: [UInt8]) -> Bool {
        var controls = 0
        for byte in bytes {
            if byte == 0 { return true }
            // Tab, line ends, form feed, the DOS end-of-file mark and Escape occur in text.
            if byte < 0x20, ![0x09, 0x0A, 0x0D, 0x0C, 0x1A, 0x1B].contains(byte) { controls += 1 }
        }
        return controls * 20 > bytes.count
    }

    enum UTF8Validity {
        case ascii, multiByte, invalid
    }

    static func utf8Validity(_ bytes: [UInt8], mayBeCutOff: Bool) -> UTF8Validity {
        var text = DecodedText()
        let used = ViewerEncoding.utf8.decode(bytes, final: false, into: &text)
        // A sequence that only lacks its end is fine when the sample was cut off there.
        if used < bytes.count, !(mayBeCutOff && bytes.count - used < 4) { return .invalid }
        if text.units.contains(CodeTable.replacement), !containsReplacementCharacter(bytes) { return .invalid }
        return text.units.count == used ? .ascii : .multiByte
    }

    /// Whether U+FFFD itself (EF BF BD) is in the bytes, in which case seeing it decoded proves nothing.
    private static func containsReplacementCharacter(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 3 else { return false }
        return (0..<bytes.count - 2).contains { bytes[$0] == 0xEF && bytes[$0 + 1] == 0xBF && bytes[$0 + 2] == 0xBD }
    }

    /// DOS or Windows code page (spec 10 › Start-up word, "Font at startup = Autodetect").
    /// Points for DOS: box-drawing bytes next to each other (frames and lines), and bytes
    /// 0x80–0x9F inside words (DOS has letters there, Windows punctuation or nothing). Points
    /// for Windows: bytes from 0xC0 up inside words, where Windows has its accented letters.
    static func looksLikeDOS(_ bytes: [UInt8]) -> Bool {
        func isLetter(_ byte: UInt8) -> Bool { (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) }
        func isBox(_ byte: UInt8) -> Bool { (0xB0...0xDF).contains(byte) }
        var dos = 0
        var windows = 0
        for (index, byte) in bytes.enumerated() where byte >= 0x80 {
            let before = index > 0 ? bytes[index - 1] : 0x20
            let after = index + 1 < bytes.count ? bytes[index + 1] : 0x20
            let inWord = isLetter(before) || isLetter(after)
            if isBox(byte), isBox(before) || isBox(after) {
                dos += 1
            } else if byte < 0xA0 {
                if inWord { dos += 1 }
            } else if byte >= 0xC0, inWord {
                windows += 1
            }
        }
        return dos > windows
    }

    /// What a file is, beyond text and binary, by its name and its first bytes.
    enum Content: Equatable {
        case image, media, pdf, html, rtf, other
    }

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "jpe", "jfif", "gif", "bmp", "dib", "tif", "tiff", "heic", "heif", "webp",
        "icns", "ico", "cur", "psd", "tga", "jp2", "j2k", "avif", "dng", "cr2", "nef", "arw", "raf", "orf"
    ]
    static let mediaExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aif", "aiff", "aifc", "caf", "flac", "mp4", "m4v", "mov", "mpg",
        "mpeg", "avi", "3gp", "m4b", "mp2", "au", "snd", "ac3", "amr"
    ]
    static let htmlExtensions: Set<String> = ["html", "htm", "xhtml", "shtml"]

    /// `additionalMedia` and `vetoed` are lists of extensions from the configuration
    /// (spec 10 › Type lists and vetoes).
    static func content(name: String, sample: Data, additionalMedia: Set<String> = [], vetoed: Set<String> = [])
        -> Content
    {
        let ext = (name as NSString).pathExtension.lowercased()
        let head = [UInt8](sample.prefix(16))
        func starts(_ signature: [UInt8], at offset: Int = 0) -> Bool {
            head.count >= offset + signature.count && Array(head[offset..<offset + signature.count]) == signature
        }
        if starts(Array("%PDF-".utf8)) || ext == "pdf" { return .pdf }
        if starts(Array("{\\rtf".utf8)) { return .rtf }
        if !vetoed.contains(ext) {
            let isImageByContent =
                starts([0x89, 0x50, 0x4E, 0x47]) || starts([0xFF, 0xD8, 0xFF]) || starts(Array("GIF8".utf8))
                || (starts(Array("BM".utf8)) && ext == "bmp")
                || (starts(Array("RIFF".utf8)) && starts(Array("WEBP".utf8), at: 8))
            if isImageByContent || imageExtensions.contains(ext) { return .image }
            if mediaExtensions.contains(ext) || additionalMedia.contains(ext) { return .media }
        }
        if htmlExtensions.contains(ext) { return .html }
        let start = String(decoding: sample.prefix(256), as: UTF8.self).lowercased().drop {
            $0.isWhitespace || $0 == "\u{FEFF}"
        }
        if start.hasPrefix("<!doctype html") || start.hasPrefix("<html") { return .html }
        return .other
    }

    /// The extensions in a list such as `*.mkv *.wmv` or `mkv, wmv`.
    static func extensions(in list: String) -> Set<String> {
        Set(
            list.lowercased().split(whereSeparator: { " ,;|".contains($0) }).map {
                String($0.drop { "*.".contains($0) })
            }.filter { !$0.isEmpty })
    }

    /// The character set an HTML file names in its head (`<meta charset=…>`, or the
    /// `http-equiv` form), if any (spec 10 › HTML text).
    static func htmlCharset(_ sample: Data) -> ViewerEncoding? {
        let head = String(decoding: sample.prefix(4_096), as: UTF8.self).lowercased()
        guard let range = head.range(of: "charset=") else { return nil }
        let name = head[range.upperBound...].drop { "\"' ".contains($0) }.prefix {
            $0.isLetter || $0.isNumber || "-_".contains($0)
        }
        switch name {
        case "utf-8", "utf8": return .utf8
        case "utf-16", "utf-16le": return .utf16LE
        case "utf-16be": return .utf16BE
        case "iso-8859-1", "latin1": return .latin1
        case "macintosh": return .macRoman

        default:
            if name.hasPrefix("windows-"), let number = Int(name.dropFirst(8)) {
                return ViewerEncoding.codePage(number)
            }
            return nil
        }
    }
}
