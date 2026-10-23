/// The line break at the end of a line, kept so that a file is written back with the breaks it had.
public enum LineEnding: String, Equatable, Sendable {
    /// `\r`, the line break of the classic Mac OS.
    case carriageReturn = "\r"
    /// `\r\n`, the line break of Windows.
    case carriageReturnLineFeed = "\r\n"
    /// `\n`, the line break of macOS and Unix.
    case lineFeed = "\n"
    /// No line break: the last line of a file that does not end with one.
    case noBreak = ""
}
