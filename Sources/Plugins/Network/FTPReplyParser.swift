/// Puts the lines of the control connection together into replies.
///
/// A reply of several lines starts with `123-` and ends with a line that starts with the same code
/// and a space; the lines between may look like anything (RFC 959 › 4.2). A reply is kept up to
/// `FTPLimits.replyLines` lines and `FTPLimits.replyBytes` bytes; of a longer one the first lines
/// and the last are kept, so the memory a reply takes has a limit.
public struct FTPReplyParser {
    private var code: Int?
    private var lines: [String] = []
    private var bytes = 0
    /// The lines of the reply that is being read, also those that were not kept.
    public private(set) var linesOfOpenReply = 0

    /// A parser that waits for the first line of a reply.
    public init() {
        // Nothing to set up: no reply is open.
    }

    /// Returns a reply when `line` completes one.
    public mutating func feed(_ line: String) -> FTPReply? {
        let digits = line.utf8.prefix(3)
        let number =
            digits.count == 3 && digits.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
            ? digits.reduce(0) { value, digit in value * 10 + Int(digit - 0x30) } : nil
        let separator = line.utf8.dropFirst(3).first
        // The line without the code and the one character that follows it. Only called when the line starts
        // with three ASCII digits, so the first three scalars are the code.
        func text() -> String {
            String(line.unicodeScalars.dropFirst(4))
        }
        if let open = code {
            if number == open, separator == 0x20 || separator == nil {
                // The last line is the one a message shows; it is kept whatever came before.
                var all = lines
                all.append(String(text().prefix(FTPLimits.lineLength)))
                (code, lines, bytes, linesOfOpenReply) = (nil, [], 0, 0)
                return FTPReply(code: open, lines: all)
            }
            // Inside a reply: the code is repeated by some servers and left out by others.
            keep(number == open && separator == 0x2D ? text() : line)
            return nil
        }
        guard let number else {
            return nil
        }
        if separator == 0x2D {
            code = number
            (lines, bytes, linesOfOpenReply) = ([], 0, 0)
            keep(text())
            return nil
        }
        return FTPReply(code: number, lines: [text()])
    }

    /// Counts a line of the open reply and keeps it while the reply is within its limits.
    private mutating func keep(_ line: String) {
        linesOfOpenReply += 1
        guard lines.count < FTPLimits.replyLines, bytes + line.utf8.count <= FTPLimits.replyBytes else {
            return
        }
        bytes += line.utf8.count
        lines.append(line)
    }
}
