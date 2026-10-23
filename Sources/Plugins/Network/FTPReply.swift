/// One answer of an FTP server: a three-digit code and the text lines that came with it.
public struct FTPReply: Equatable, Sendable {
    /// The three-digit reply code (RFC 959 › 4.2), 100 to 999.
    public let code: Int
    /// The text of every line, without the code and without the line ends.
    public let lines: [String]

    /// The lines joined with line feeds, as one text.
    public var text: String { lines.joined(separator: "\n") }
    /// 1xx: the transfer is starting, another reply follows.
    public var isPreliminary: Bool { code / 100 == 1 }
    /// 2xx: done.
    public var isSuccess: Bool { code / 100 == 2 }
    /// 3xx: the server waits for the next command of a sequence (PASS after USER, RNTO after RNFR).
    public var isIntermediate: Bool { code / 100 == 3 }
    /// The reply as it is shown to the user.
    public var message: String { "\(code) \(lines.last ?? "")" }

    /// A reply with the given code and text lines (without codes or line ends).
    public init(code: Int, lines: [String]) {
        self.code = code
        self.lines = lines
    }
}
