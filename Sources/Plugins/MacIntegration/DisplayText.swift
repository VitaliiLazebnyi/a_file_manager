import Foundation

// The same as in the Configuration plugin: plugins share no code but the kernel's.

/// Text that came from outside (a file name, a path, a stored value) made fit for a message, a
/// log line or a dialog: line breaks and control characters cannot draw a second line or hide
/// what follows, and a very long text is cut.
internal enum DisplayText {
    /// `text` on one line, cut after 200 characters.
    internal static func oneLine(_ text: String) -> String {
        oneLine(text, limit: 200)
    }

    /// `text` on one line: line breaks, tabs and invisible characters written out as escapes
    /// (the joiners of emoji kept), cut after `limit` characters with `…`.
    internal static func oneLine(_ text: String, limit: Int) -> String {
        var result = String.UnicodeScalarView()
        var count = 0
        for scalar in text.unicodeScalars {
            if count >= limit {
                result.append("…")
                break
            }
            count += 1
            switch scalar {
            case "\n":
                result.append(contentsOf: "\\n".unicodeScalars)

            case "\r":
                result.append(contentsOf: "\\r".unicodeScalars)

            case "\t":
                result.append(contentsOf: "\\t".unicodeScalars)

            default:
                switch scalar.properties.generalCategory {
                // The joiners of emoji and of some scripts are format characters too, and harmless.
                case .format where scalar.value == 0x200C || scalar.value == 0x200D:
                    result.append(scalar)

                case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate:
                    result.append(contentsOf: "\\u{\(String(scalar.value, radix: 16, uppercase: true))}".unicodeScalars)

                default:
                    result.append(scalar)
                }
            }
        }
        return String(result)
    }
}
