public import Foundation

/// One answer of an FTP server: a three-digit code and the text lines that came with it.
public struct FTPReply: Equatable, Sendable {
    public let code: Int
    /// The text of every line, without the code and without the line ends.
    public let lines: [String]

    public init(code: Int, lines: [String]) {
        self.code = code
        self.lines = lines
    }

    public var text: String { lines.joined(separator: "\n") }
    /// 1xx: the transfer is starting, another reply follows.
    public var isPreliminary: Bool { code / 100 == 1 }
    /// 2xx: done.
    public var isSuccess: Bool { code / 100 == 2 }
    /// 3xx: the server waits for the next command of a sequence (PASS after USER, RNTO after RNFR).
    public var isIntermediate: Bool { code / 100 == 3 }
    /// The reply as it is shown to the user.
    public var message: String { "\(code) \(lines.last ?? "")" }
}

/// What is taken from a server before it is called a hostile one.
///
/// No command of the protocol needs anywhere near this much.
public enum FTPLimits {
    /// The longest line of a reply, and of a listing, in bytes.
    public static let lineLength = 4_096
    /// The lines and bytes of one reply that are kept; what comes beyond is dropped.
    public static let replyLines = 1_000
    public static let replyBytes = 64 * 1_024
    /// The lines of one reply that are read at all before the connection is given up.
    public static let replyLinesRead = 20_000
    /// The entries and bytes of one directory listing.
    public static let listingEntries = 4_000_000
    public static let listingBytes: Int64 = 1 << 30
}

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

    public init() {}

    private mutating func keep(_ line: String) {
        linesOfOpenReply += 1
        guard lines.count < FTPLimits.replyLines, bytes + line.utf8.count <= FTPLimits.replyBytes else {
            return
        }
        bytes += line.utf8.count
        lines.append(line)
    }

    /// Returns a reply when `line` completes one.
    public mutating func feed(_ line: String) -> FTPReply? {
        let digits = line.utf8.prefix(3)
        let number =
            digits.count == 3 && digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 })
            ? Int(String(decoding: digits, as: UTF8.self)) : nil
        let separator = line.utf8.dropFirst(3).first
        /// The line without the code and the one character that follows it.
        func text() -> String {
            var rest = String(decoding: line.utf8.dropFirst(3), as: UTF8.self).unicodeScalars
            if !rest.isEmpty { rest.removeFirst() }
            return String(rest)
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
}

/// Cuts what a data connection delivers into lines, block by block.
///
/// Every byte is looked at once, whatever the sizes of the blocks; a line longer than `limit` is
/// dropped whole, so the part of a line that is waiting for its end never grows beyond the limit.
internal struct LineSplitter {
    internal let limit: Int
    private var partial = Data()
    /// True while the rest of a line that was too long is being skipped.
    private var isSkipping = false
    /// How many lines were dropped for their length.
    internal private(set) var dropped = 0

    internal init(limit: Int = FTPLimits.lineLength) {
        self.limit = limit
    }

    /// The lines that `block` completes, without their line ends (LF, or CR LF).
    internal mutating func feed(_ block: Data) -> [Data] {
        var lines: [Data] = []
        var start = block.startIndex
        while start < block.endIndex {
            guard let end = block[start...].firstIndex(of: 0x0A) else {
                if !isSkipping {
                    if partial.count + (block.endIndex - start) > limit {
                        (isSkipping, partial) = (true, Data())
                        dropped += 1
                    } else {
                        partial.append(block[start...])
                    }
                }
                break
            }
            if isSkipping {
                isSkipping = false
            } else if partial.count + (end - start) > limit + 1 {
                partial = Data()
                dropped += 1
            } else {
                var line = partial.isEmpty ? Data(block[start..<end]) : partial + block[start..<end]
                partial = Data()
                if line.last == 0x0D { line.removeLast() }
                lines.append(line)
            }
            start = end + 1
        }
        return lines
    }

    /// What is left when the data ends without a line end.
    internal mutating func finish() -> Data? {
        defer { (partial, isSkipping) = (Data(), false) }
        if isSkipping || partial.isEmpty {
            return nil
        }
        return partial.last == 0x0D ? Data(partial.dropLast()) : partial
    }
}

/// The pieces of FTP replies that have a syntax of their own.
public enum FTPSyntax {
    /// The port in the reply to EPSV: `229 Entering Extended Passive Mode (|||6446|)`.
    public static func extendedPassivePort(_ text: String) -> Int? {
        guard let open = text.lastIndex(of: "("), let close = text[open...].firstIndex(of: ")") else {
            return nil
        }
        let inner = text[text.index(after: open)..<close]
        guard let delimiter = inner.first else {
            return nil
        }
        let fields = inner.split(separator: delimiter, omittingEmptySubsequences: false)
        guard fields.count >= 5, let port = Int(fields[3]), (1...65_535).contains(port) else {
            return nil
        }
        return port
    }

    /// Host and port in the reply to PASV: `227 Entering Passive Mode (192,168,1,2,19,137)`.
    ///
    /// The brackets are left out by some servers.
    public static func passiveEndpoint(_ text: String) -> (host: String, port: Int)? {
        var numbers: [Int] = []
        var best: [Int] = []
        var current = ""
        // The six numbers are the last run of comma-separated numbers in the text.
        for character in text + " " {
            if character.isASCII, character.isNumber {
                current.append(character)
            } else {
                if !current.isEmpty {
                    numbers.append(Int(current) ?? 999)
                    current = ""
                }
                if character != "," {
                    if numbers.count == 6 { best = numbers }
                    numbers = []
                }
            }
        }
        guard best.count == 6, best.allSatisfy({ (0...255).contains($0) }) else {
            return nil
        }
        let port = best[4] * 256 + best[5]
        guard port > 0 else {
            return nil
        }
        return (best[0..<4].map(String.init).joined(separator: "."), port)
    }

    /// The argument of PORT for an IPv4 address: `h1,h2,h3,h4,p1,p2`.
    public static func portArgument(host: String, port: Int) -> String? {
        let parts = host.split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else {
            return nil
        }
        return (parts.map(String.init) + [String(port / 256), String(port % 256)]).joined(separator: ",")
    }

    /// The argument of EPRT: `|1|132.235.1.2|6275|` or `|2|1080::8:800:200C:417A|5282|`.
    public static func extendedPortArgument(host: String, port: Int) -> String {
        "|\(host.contains(":") ? 2 : 1)|\(host)|\(port)|"
    }

    /// The features in the reply to FEAT, by upper-case name, with what follows the name
    /// (`MLST` → `type*;size*;modify*;`).
    public static func features(_ reply: FTPReply) -> [String: String] {
        var features: [String: String] = [:]
        for line in reply.lines.dropFirst().dropLast() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            features[parts[0].uppercased()] = parts.count > 1 ? String(parts[1]) : ""
        }
        return features
    }

    /// The directory in the reply to PWD or MKD: `257 "/a ""quoted"" name" created`.
    public static func quotedPath(_ text: String) -> String? {
        guard let open = text.firstIndex(of: "\"") else {
            return nil
        }
        var path = ""
        var index = text.index(after: open)
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "\"" {
                // A doubled quote stands for one quote inside the name.
                guard next < text.endIndex, text[next] == "\"" else {
                    return path
                }
                path.append("\"")
                index = text.index(after: next)
            } else {
                path.append(character)
                index = next
            }
        }
        return nil
    }

    /// A time as MDTM, MFMT and MLSD write it: `YYYYMMDDHHMMSS[.sss]`, in UTC.
    public static func time(_ text: String) -> Date? {
        let digits = text.prefix(14)
        guard digits.count == 14, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        // Fourteen ASCII digits, read as numbers one by one.
        let values = digits.compactMap(\.wholeNumberValue)
        func number(_ from: Int, _ length: Int) -> Int {
            values[from..<from + length].reduce(0) { $0 * 10 + $1 }
        }
        var components = DateComponents()
        (components.year, components.month, components.day) = (number(0, 4), number(4, 2), number(6, 2))
        (components.hour, components.minute, components.second) = (number(8, 2), number(10, 2), number(12, 2))
        return FTPListParser.date(components, calendar: utc)
    }

    public static func timeText(_ date: Date) -> String {
        let parts: [Calendar.Component] = [.year, .month, .day, .hour, .minute, .second]
        return String(format: "%04d%02d%02d%02d%02d%02d", arguments: parts.map { utc.component($0, from: date) })
    }

    internal static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()
}
