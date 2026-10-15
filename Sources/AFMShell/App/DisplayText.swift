/// Names as they may be shown.
///
/// A file's name is whatever its file system or a server says it is, line breaks and
/// writing-direction controls included: such a name can hide its real ending behind a second
/// line, or show its letters in another order (`exe.txt` for a name that ends in `.exe`). For
/// display, and only there, every such character is replaced by a sign that can be seen.
internal enum DisplayText {
    /// `text` with control characters, line breaks and direction controls made visible.
    internal static func clean(_ text: String) -> String {
        clean(text, keepingLines: false)
    }

    /// `text` with control characters and direction controls made visible.
    ///
    /// Line breaks and tabs stay as they are with `keepingLines` (the text of a dialog).
    internal static func clean(_ text: String, keepingLines: Bool) -> String {
        // Nearly every name has none of them; that is found out from its bytes alone.
        let suspicious = text.utf8.contains { byte in
            byte < 0x20 || byte == 0x7F || byte == 0xC2 || byte == 0xD8 || byte == 0xE2
        }
        guard suspicious else {
            return text
        }
        var cleaned = String.UnicodeScalarView()
        var changed = false
        for scalar in text.unicodeScalars {
            if let replacement = replacement(for: scalar, keepingLines: keepingLines) {
                cleaned.append(replacement)
                changed = true
            } else {
                cleaned.append(scalar)
            }
        }
        return changed ? String(cleaned) : text
    }

    /// The visible sign that stands for `scalar`; nil for a character shown as it is.
    private static func replacement(for scalar: Unicode.Scalar, keepingLines: Bool) -> Unicode.Scalar? {
        switch scalar.value {
        case 0x0A, 0x09, 0x0D:
            return keepingLines ? nil : Unicode.Scalar(0x2400 + scalar.value)

        case 0x00...0x1F:
            // The "control pictures": ␀ ␁ … ␛.
            return Unicode.Scalar(0x2400 + scalar.value)

        case 0x7F:
            return "\u{2421}"

        case 0x80...0x9F, 0x061C, 0x200E, 0x200F, 0x2028, 0x2029, 0x202A...0x202E, 0x2066...0x2069:
            return "\u{FFFD}"

        default:
            return nil
        }
    }
}
