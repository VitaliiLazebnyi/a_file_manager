import AFMKernel
public import Foundation

/// One entry of a directory on a server, as far as the server told.
public struct RemoteEntry: Equatable, Sendable {
    public var name: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    /// Where a symbolic link points, when the listing says so.
    public var linkTarget: String?
    public var size: Int64
    public var modified: Date?
    public var permissions: UInt16?
    /// A device, a pipe or a socket, where the listing tells the type (`FileItem.isSpecial`).
    public var isSpecial = false

    public init(
        name: String,
        isDirectory: Bool,
        isSymlink: Bool = false,
        linkTarget: String? = nil,
        size: Int64 = 0,
        modified: Date? = nil,
        permissions: UInt16? = nil
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.linkTarget = linkTarget
        self.size = size
        self.modified = modified
        self.permissions = permissions
    }

    /// Whether a name from a server may become a path below a local or remote folder.
    ///
    /// A name is one path component: a server that sends `../../x` or `a/b` must not be able to
    /// place a file outside the folder the user chose. `isDOSFormat` also rejects the backslash,
    /// which Windows servers use as a separator.
    ///
    /// The name must also stay one component when the path it becomes part of is read as
    /// text: a name that begins with a combining mark would melt into the slash before it
    /// (`RemotePath.hasSeparableNames`), and is left out like the others.
    internal static func isSafeName(_ name: String, isDOSFormat: Bool = false) -> Bool {
        // The kernel's check of a single name (by bytes: not empty, no `.` or `..`, no slash, no
        // zero byte), and what only a server's listing adds to it.
        guard PathSafety.isSafeName(name), !(isDOSFormat && name.utf8.contains(0x5C)) else {
            return false
        }
        return RemotePath.hasSeparableNames(name)
    }

    /// The entry as a panel shows it.
    internal func item(in directory: URL) -> FileItem {
        FileItem(
            url: directory.appending(name: name),
            name: name,
            kind: .init(
                isDirectory: isDirectory,
                isSymlink: isSymlink,
                isHidden: name.hasPrefix("."),
                isSpecial: isSpecial
            ),
            stat: .init(
                size: isDirectory ? 0 : size,
                modified: modified ?? Date(timeIntervalSince1970: 0),
                permissions: permissions ?? (isDirectory ? 0o755 : 0o644)
            )
        )
    }
}

/// Reads directory listings (spec 11 › Listing: MLSD or LIST).
///
/// MLSD is a standard; LIST is whatever the server's `ls` or `dir` prints, so that parser
/// recognises the formats in use: Unix `ls -l` in its many variants (with or without group, ACL
/// marks, device numbers, ISO dates, month names in several languages, NetWare), Windows/DOS `dir`,
/// and EPLF.
public enum FTPListParser {
    /// A line of a listing longer than this is not an entry: no server has names this long, and
    /// what a hostile one sends must not cost more than a glance.
    public static let longestLine = 4_096

    /// Sizes and dates come from the server and are taken as they fit: a size that is no
    /// number or below zero is 0, one too large for a number is the largest there is.
    internal static func size(_ digits: Substring) -> Int64 {
        guard !digits.isEmpty, digits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else {
            return 0
        }
        return Int64(digits) ?? .max
    }

    /// A date built from numbers a server sent; nil when they are not a date of our era.
    internal static func date(_ components: DateComponents, calendar: Calendar) -> Date? {
        // Every caller gives a year, a month and a day; the time of day may be left out.
        guard let year = components.year, (1...9_999).contains(year), let month = components.month,
            (1...12).contains(month), let day = components.day, (1...31).contains(day),
            (0...24).contains(components.hour ?? 0), (0...59).contains(components.minute ?? 0),
            (0...60).contains(components.second ?? 0)
        else { return nil }
        return calendar.date(from: components)
    }

    // MARK: MLSD

    /// One line of MLSD: `type=file;size=12;modify=20240102030405; name`.
    ///
    /// The entries for the directory itself and its parent give nil.
    public static func mlsd(_ line: String) -> RemoteEntry? {
        guard let entry = parseMLSD(line), RemoteEntry.isSafeName(entry.name) else {
            return nil
        }
        return entry
    }

    /// `mlsd` without the check of the name, which MLST needs: it names a whole path.
    private static func parseMLSD(_ line: String) -> RemoteEntry? {
        // Found by its byte: a space followed by a combining mark is one character, and still the separator.
        guard line.utf8.count <= longestLine, let space = line.utf8.firstIndex(of: 0x20) else {
            return nil
        }
        let name = String(decoding: line.utf8[line.utf8.index(after: space)...], as: UTF8.self)
        guard !name.isEmpty, name != ".", name != ".." else {
            return nil
        }
        var entry = RemoteEntry(name: name, isDirectory: false)
        let facts = String(decoding: line.utf8[..<space], as: UTF8.self)
        for fact in facts.split(separator: ";") {
            guard let equals = fact.firstIndex(of: "=") else { continue }
            let value = String(fact[fact.index(after: equals)...])
            switch fact[..<equals].lowercased() {
            case "type":
                let type = value.lowercased()
                if type == "cdir" || type == "pdir" {
                    return nil
                }
                if type == "dir" {
                    entry.isDirectory = true
                } else if type.hasPrefix("os.unix=slink") || type.hasPrefix("os.unix=symlink") {
                    entry.isSymlink = true
                    if let colon = value.firstIndex(of: ":") {
                        entry.linkTarget = String(value[value.index(after: colon)...])
                    }
                }

            case "size", "sizd":
                entry.size = size(Substring(value))

            case "modify":
                entry.modified = FTPSyntax.time(value)

            case "unix.mode":
                entry.permissions = UInt16(value, radix: 8).map { $0 & 0o7777 }

            default:
                break
            }
        }
        return entry
    }

    /// The line inside the reply to MLST.
    ///
    /// It is indented by a space, and the name may be a whole path.
    public static func mlst(_ line: String) -> RemoteEntry? {
        guard var entry = parseMLSD(line.hasPrefix(" ") ? String(line.dropFirst()) : line) else {
            return nil
        }
        entry.name = RemotePath.name(of: entry.name)
        return RemoteEntry.isSafeName(entry.name) ? entry : nil
    }

    // MARK: LIST

    /// One line of LIST in any of the known formats; nil for lines that are no entry (`total 12`,
    /// `.` and `..`, blank lines, messages, lines longer than `longestLine`). Times without a
    /// zone are taken as `calendar`'s.
    ///
    /// The line is read by hand, token by token, in one pass per format: the time a line takes
    /// grows with its length and with nothing else, whatever a server puts into it.
    public static func list(_ line: String, now: Date = Date(), calendar: Calendar = localCalendar) -> RemoteEntry? {
        guard line.utf8.count <= longestLine + 1 else {
            return nil
        }
        var scalars = Array(line.unicodeScalars)
        if scalars.last == "\r" { scalars.removeLast() }
        guard let first = scalars.first else {
            return nil
        }
        let entry: RemoteEntry?
        var isDOS = false
        if first == "+" {
            entry = eplf(scalars)
        } else if first.properties.numericType != nil, let dos = dos(scalars, calendar: calendar) {
            entry = dos
            isDOS = true
        } else {
            entry = unix(scalars, now: now, calendar: calendar)
        }
        guard let entry, RemoteEntry.isSafeName(entry.name, isDOSFormat: isDOS) else {
            return nil
        }
        return entry
    }

    /// A whole listing.
    ///
    /// Large ones are parsed on all cores.
    public static func entries(
        of lines: [String],
        asMLSD: Bool,
        now: Date = Date(),
        calendar: Calendar = localCalendar
    ) -> [RemoteEntry] {
        Parallel.map(lines, serialBelow: 2_000) { asMLSD ? mlsd($0) : list($0, now: now, calendar: calendar) }
            .compactMap { $0 }
    }

    public static let localCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    // MARK: Reading a line by hand

    private typealias Scalars = [Unicode.Scalar]

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool { scalar.value >= 0x30 && scalar.value <= 0x39 }
    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.isWhitespace }
    private static func text(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// The runs between white space, as ranges of the line.
    private static func tokens(_ line: Scalars) -> [Range<Int>] {
        var tokens: [Range<Int>] = []
        var start: Int?
        for (index, scalar) in line.enumerated() {
            if isSpace(scalar) {
                if let begun = start {
                    tokens.append(begun..<index)
                    start = nil
                }
            } else if start == nil {
                start = index
            }
        }
        if let begun = start { tokens.append(begun..<line.count) }
        return tokens
    }

    /// The number a run of one to `most` digits spells, when the token is nothing else.
    private static func number(_ token: ArraySlice<Unicode.Scalar>, digits: ClosedRange<Int>) -> Int? {
        guard digits.contains(token.count), token.allSatisfy(isDigit) else {
            return nil
        }
        return Int(text(token))
    }

    /// The digits a token ends with: the size stands at the end of what comes before the date,
    /// and with device numbers (`3, 2`) or a missing gap it is not a token of its own.
    private static func trailingSize(_ token: ArraySlice<Unicode.Scalar>) -> Int64? {
        var start = token.endIndex
        while start > token.startIndex, isDigit(token[start - 1]) { start -= 1 }
        guard start < token.endIndex else {
            return nil
        }
        return size(Substring(text(token[start...])))
    }

    /// `12:34` or `12:34:56`, optionally with a fraction of a second.
    private static func clockTime(_ token: ArraySlice<Unicode.Scalar>, allowsFraction: Bool) -> (
        hour: Int, minute: Int, second: Int?
    )? {
        var parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else {
            return nil
        }
        if allowsFraction, let last = parts.last, let dot = last.firstIndex(of: ".") {
            guard dot + 1 < last.endIndex, last[(dot + 1)...].allSatisfy(isDigit) else {
                return nil
            }
            parts[parts.count - 1] = last[..<dot]
        }
        guard let hour = number(parts[0], digits: 1...2), let minute = number(parts[1], digits: 2...2) else {
            return nil
        }
        if parts.count == 2 {
            return (hour, minute, nil)
        }
        guard let second = number(parts[2], digits: 2...2) else {
            return nil
        }
        return (hour, minute, second)
    }

    /// The name: everything after the one white space that follows the date.
    private static func rest(_ line: Scalars, after token: Range<Int>) -> String? {
        let start = token.upperBound + 1
        guard start < line.count else {
            return nil
        }
        return text(line[start...])
    }

    // MARK: Unix

    private static let months: [String: Int] = {
        let names: [[String]] = [
            ["jan", "ene", "gen", "janv"], ["feb", "fev", "fév", "févr"], ["mar", "mär", "mrz", "mars"],
            ["apr", "avr", "abr"],
            ["may", "mai", "mag", "mei"], ["jun", "juin", "giu"], ["jul", "juil", "lug"],
            ["aug", "aou", "aoû", "août", "ago"],
            ["sep", "sept", "set"], ["oct", "okt", "ott", "out"], ["nov"], ["dec", "dez", "déc", "dic"]
        ]
        var months: [String: Int] = [:]
        for (index, group) in names.enumerated() {
            for name in group { months[name] = index + 1 }
        }
        return months
    }()

    /// The month a token names: three to five letters, with or without a full stop.
    private static func monthNumber(_ token: ArraySlice<Unicode.Scalar>) -> Int? {
        var letters = token
        if letters.last == "." { letters = letters.dropLast() }
        guard (3...5).contains(letters.count),
            letters.allSatisfy({
                ($0.value >= 0x41 && $0.value <= 0x5A) || ($0.value >= 0x61 && $0.value <= 0x7A)
                    || ($0.value >= 0xC0 && $0.value <= 0x24F)
            })
        else { return nil }
        return months[text(letters).lowercased()]
    }

    /// The day of a month: one or two digits, with a full stop where the day comes first.
    private static func dayNumber(_ token: ArraySlice<Unicode.Scalar>, allowsStop: Bool) -> Int? {
        var digits = token
        if allowsStop, digits.last == "." { digits = digits.dropLast() }
        guard let found = number(digits, digits: 1...2), (1...31).contains(found) else {
            return nil
        }
        return found
    }

    /// What every `ls -l` variant ends with, in the three ways servers write the date:
    /// `<size> <month> <day> <year or time> <name>`, the same with the day before the month (as
    /// some European servers print it), and `<size> 2024-01-31 12:34 <name>`
    /// (`ls --time-style=long-iso`, some newer servers).
    ///
    /// The first place of the line that reads as one of them is taken, the forms tried in this
    /// order.
    private static func unix(_ line: Scalars, now: Date, calendar: Calendar) -> RemoteEntry? {
        let characters = Array(line.prefix(10))
        guard let type = characters.first, "-dlbcpsDw".unicodeScalars.contains(type) else {
            return nil
        }
        // Either a full mode string (`-rwxr-xr-x`) or NetWare's `d [RWCEAFMS]`.
        let hasMode =
            characters.count == 10 && characters.dropFirst().allSatisfy { "-rwxsStTlL".unicodeScalars.contains($0) }
        guard hasMode || line.dropFirst().drop(while: { $0 == " " }).first == "[" else {
            return nil
        }

        var entry = RemoteEntry(name: "", isDirectory: type == "d" || type == "D", isSymlink: type == "l")
        entry.isSpecial = "cbps".unicodeScalars.contains(type)
        let tokens = Self.tokens(line)
        var name: String?

        // <size> <month> <day> <year|time> <name>, then <size> <day> <month> <year|time> <name>.
        for dayFirst in [false, true] where name == nil {
            var index = 1
            while index + 2 < tokens.count, name == nil {
                defer { index += 1 }
                let (monthToken, dayToken) =
                    dayFirst
                    ? (line[tokens[index + 1]], line[tokens[index]]) : (line[tokens[index]], line[tokens[index + 1]])
                guard let month = monthNumber(monthToken), let day = dayNumber(dayToken, allowsStop: dayFirst),
                    let size = trailingSize(line[tokens[index - 1]])
                else { continue }
                let last = line[tokens[index + 2]]
                var components = DateComponents()
                (components.month, components.day) = (month, day)
                let modified: Date?
                if let year = number(last, digits: 4...4) {
                    components.year = year
                    modified = date(components, calendar: calendar)
                } else if let time = clockTime(last, allowsFraction: false) {
                    (components.hour, components.minute, components.second) = (time.hour, time.minute, time.second)
                    modified = recent(components, now: now, calendar: calendar)
                } else {
                    continue
                }
                guard let found = rest(line, after: tokens[index + 2]) else { continue }
                (entry.size, entry.modified, name) = (size, modified, found)
            }
        }
        // <size> 2024-01-31 12:34[:56][.789] [+0100] <name>
        var index = 1
        while name == nil, index + 1 < tokens.count {
            defer { index += 1 }
            let parts = line[tokens[index]].split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 3, let year = number(parts[0], digits: 4...4),
                let month = number(parts[1], digits: 2...2),
                let dayOfMonth = number(parts[2], digits: 2...2),
                let time = clockTime(line[tokens[index + 1]], allowsFraction: true),
                let size = trailingSize(line[tokens[index - 1]])
            else { continue }
            var last = tokens[index + 1]
            // A time zone, when exactly one space leads to it and a name follows it.
            if index + 2 < tokens.count, tokens[index + 2].lowerBound == last.upperBound + 1 {
                let zone = line[tokens[index + 2]]
                if zone.count == 5, zone.first == "+" || zone.first == "-", zone.dropFirst().allSatisfy(isDigit),
                    tokens[index + 2].upperBound + 1 < line.count
                {
                    last = tokens[index + 2]
                }
            }
            guard let found = rest(line, after: last) else { continue }
            var components = DateComponents()
            (components.year, components.month, components.day) = (year, month, dayOfMonth)
            (components.hour, components.minute) = (time.hour, time.minute)
            (entry.size, entry.modified, name) = (size, date(components, calendar: calendar), found)
        }
        guard var name else {
            return nil
        }
        if entry.isSymlink, let arrow = name.range(of: " -> ") {
            entry.linkTarget = String(name[arrow.upperBound...])
            name = String(name[..<arrow.lowerBound])
        }
        entry.name = name
        if hasMode { entry.permissions = permissions(ArraySlice(characters.dropFirst().map(Character.init))) }
        return entry
    }

    /// `rwxr-sr-t` as permission bits, with set-user-id, set-group-id and sticky.
    internal static func permissions(_ mode: ArraySlice<Character>) -> UInt16 {
        var bits: UInt16 = 0
        for (index, character) in mode.prefix(9).enumerated() {
            let bit = UInt16(1) << UInt16(8 - index)
            let special: UInt16 = index == 2 ? 0o4000 : index == 5 ? 0o2000 : 0o1000
            switch character {
            case "r", "w", "x":
                bits |= bit

            case "s", "t":
                bits |= bit | special

            case "S", "T":
                bits |= special

            default:
                break
            }
        }
        return bits
    }

    /// `ls` leaves out the year for the last six months: a date with a time and no year.
    private static func recent(_ parts: DateComponents, now: Date, calendar: Calendar) -> Date? {
        var components = parts
        let thisYear = calendar.component(.year, from: now)
        components.year = thisYear
        guard let date = date(components, calendar: calendar) else {
            return nil
        }
        // A date without a year lies in the past; a day of slack covers the server's time zone.
        if date > now.addingTimeInterval(86_400) {
            components.year = thisYear - 1
            return self.date(components, calendar: calendar)
        }
        return date
    }

    // MARK: Windows/DOS

    /// `01-31-24  03:04PM       <DIR>          name` or `01-31-2024  15:04  1,234 name`.
    private static func dos(_ line: Scalars, calendar: Calendar) -> RemoteEntry? {
        var position = 0
        func digits(_ range: ClosedRange<Int>) -> Int? {
            var end = position
            while end < line.count, isDigit(line[end]) { end += 1 }
            guard range.contains(end - position) else {
                return nil
            }
            defer { position = end }
            return Int(text(line[position..<end]))
        }
        func separator() -> Bool {
            guard position < line.count, line[position] == "-" || line[position] == "/" || line[position] == "." else {
                return false
            }
            position += 1
            return true
        }
        /// Skips white space and tells how much there was.
        func space() -> Int {
            let start = position
            while position < line.count, isSpace(line[position]) { position += 1 }
            return position - start
        }
        guard let month = digits(2...2), separator(), let day = digits(2...2), separator(), var year = digits(2...4),
            space() > 0,
            var hour = digits(1...2), position < line.count, line[position] == ":"
        else { return nil }
        position += 1
        guard let minute = digits(2...2) else {
            return nil
        }
        var gap = space()
        if position < line.count, "AaPp".unicodeScalars.contains(line[position]) {
            let isAfternoon = line[position] == "P" || line[position] == "p"
            position += 1
            if position < line.count, line[position] == "M" || line[position] == "m" { position += 1 }
            if isAfternoon, hour < 12 { hour += 12 }
            if !isAfternoon, hour == 12 { hour = 0 }
            gap = space()
        }
        guard gap > 0 else {
            return nil
        }
        let kindStart = position
        var isDirectory = false
        var isLink = false
        var size: Int64 = 0
        if position < line.count, line[position] == "<" {
            while position < line.count, line[position] != ">", !isSpace(line[position]) { position += 1 }
            guard position < line.count, line[position] == ">" else {
                return nil
            }
            position += 1
            let kind = text(line[kindStart..<position])
            guard ["<DIR>", "<JUNCTION>", "<SYMLINK>", "<SYMLINKD>"].contains(kind) else {
                return nil
            }
            (isDirectory, isLink) = (true, kind != "<DIR>")
        } else {
            while position < line.count, isDigit(line[position]) || line[position] == "." || line[position] == "," {
                position += 1
            }
            guard position > kindStart else {
                return nil
            }
            size = self.size(Substring(text(ArraySlice(line[kindStart..<position].filter(isDigit)))))
        }
        guard space() > 0, position < line.count else {
            return nil
        }
        if year < 100 { year += year < 70 ? 2_000 : 1_900 }
        var components = DateComponents()
        (components.year, components.month, components.day, components.hour, components.minute) = (
            year, month, day, hour, minute
        )
        var entry = RemoteEntry(name: text(line[position...]), isDirectory: isDirectory, isSymlink: isLink)
        entry.modified = date(components, calendar: calendar)
        entry.size = size
        return entry
    }

    // MARK: EPLF

    /// `+i8388621.29609,m824255902,/,\tdev` (D.
    ///
    /// J. Bernstein's Easily Parsed LIST Format).
    private static func eplf(_ line: Scalars) -> RemoteEntry? {
        guard let tab = line.firstIndex(of: "\t") else {
            return nil
        }
        var entry = RemoteEntry(name: text(line[(tab + 1)...]), isDirectory: false)
        // Empty facts are left out by the split, so every fact has a kind.
        for fact in line[1..<tab].split(separator: ",") {
            let value = text(fact.dropFirst())
            switch fact.first {
            case "/"?:
                entry.isDirectory = true

            case "s"?:
                entry.size = size(Substring(value))

            case "m"?:
                // Seconds since 1970; anything else, or a time beyond the year 9999, is no date.
                if value.utf8.count <= 12, let seconds = Int64(value), (0...253_402_300_799).contains(seconds) {
                    entry.modified = Date(timeIntervalSince1970: TimeInterval(seconds))
                }

            case "u"? where value.hasPrefix("p"):
                entry.permissions = UInt16(value.dropFirst(), radix: 8).map { $0 & 0o7777 }

            default:
                break
            }
        }
        return entry
    }
}
