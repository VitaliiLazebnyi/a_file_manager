public import Foundation

/// The pieces of FTP replies that have a syntax of their own.
public enum FTPSyntax {
    /// The Gregorian calendar in UTC, in which FTP writes its times.
    internal static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

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

    /// A time the way MFMT and MDTM want it, `YYYYMMDDHHMMSS` in UTC; the opposite of `time(_:)`.
    public static func timeText(_ date: Date) -> String {
        let parts: [Calendar.Component] = [.year, .month, .day, .hour, .minute, .second]
        return String(format: "%04d%02d%02d%02d%02d%02d", arguments: parts.map { utc.component($0, from: date) })
    }
}
