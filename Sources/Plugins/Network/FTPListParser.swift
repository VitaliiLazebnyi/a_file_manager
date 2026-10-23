import AFMKernel
public import Foundation

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

    /// The Gregorian calendar in this Mac's time zone, in which listings without a zone are read by default.
    public static let localCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

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
    /// `.` and `..`, blank lines, messages, lines longer than `longestLine`).
    ///
    /// Times without a zone are taken as `calendar`'s. The line is read by hand, token by token, in
    /// one pass per format: the time a line takes grows with its length and with nothing else,
    /// whatever a server puts into it.
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
        } else if first.properties.numericType != nil, let dos = DOSLine.entry(of: scalars, calendar: calendar) {
            entry = dos
            isDOS = true
        } else {
            entry = UnixLine(scalars, now: now, calendar: calendar)?.entry()
        }
        guard let entry, isDOS ? RemoteEntry.isSafeDOSName(entry.name) : RemoteEntry.isSafeName(entry.name) else {
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
            .compactMap(\.self)
    }

    // MARK: Pieces every format uses

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

    /// Whether a scalar is an ASCII digit (other scripts' digits are no part of a listing's numbers).
    internal static func isDigit(_ scalar: Unicode.Scalar) -> Bool { scalar.value >= 0x30 && scalar.value <= 0x39 }

    /// Whether a scalar is white space, which separates the columns of a LIST line.
    internal static func isSpace(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.isWhitespace }

    /// The scalars of a line as a string.
    internal static func text(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// `mlsd` without the check of the name, which MLST needs: it names a whole path.
    private static func parseMLSD(_ line: String) -> RemoteEntry? {
        // Found by its byte: a space followed by a combining mark is one character, and still the separator.
        guard line.utf8.count <= longestLine, let space = line.utf8.firstIndex(of: 0x20) else {
            return nil
        }
        // A space byte always ends a scalar, so the scalars on either side of it are the bytes on either side.
        let name = String(line.unicodeScalars[line.utf8.index(after: space)...])
        guard !name.isEmpty, name != ".", name != ".." else {
            return nil
        }
        var entry = RemoteEntry(name: name, isDirectory: false)
        let facts = String(line.unicodeScalars[..<space])
        for fact in facts.split(separator: ";") {
            guard let equals = fact.firstIndex(of: "=") else { continue }
            let value = String(fact[fact.index(after: equals)...])
            guard read(fact: fact[..<equals].lowercased(), value: value, into: &entry) else {
                return nil
            }
        }
        return entry
    }

    /// Takes one MLSD fact (its name in lower case) into `entry`; false for the entries of the directory
    /// itself and its parent, which are no entries.
    private static func read(fact: String, value: String, into entry: inout RemoteEntry) -> Bool {
        switch fact {
        case "type":
            return readType(value, into: &entry)

        case "size", "sizd":
            entry.size = size(Substring(value))

        case "modify":
            entry.modified = FTPSyntax.time(value)

        case "unix.mode":
            entry.permissions = UInt16(value, radix: 8).map { $0 & 0o7777 }

        default:
            break
        }
        return true
    }

    /// Takes the `type` fact of MLSD into `entry`; false for `cdir` and `pdir`.
    private static func readType(_ value: String, into entry: inout RemoteEntry) -> Bool {
        let type = value.lowercased()
        if type == "cdir" || type == "pdir" {
            return false
        }
        if type == "dir" {
            entry.isDirectory = true
        } else if type.hasPrefix("os.unix=slink") || type.hasPrefix("os.unix=symlink") {
            entry.isSymlink = true
            if let colon = value.firstIndex(of: ":") {
                entry.linkTarget = String(value[value.index(after: colon)...])
            }
        }
        return true
    }

    // MARK: EPLF

    /// A line of EPLF, Bernstein's Easily Parsed LIST Format: `+i8388621.29609,m824255902,/,\tdev`.
    private static func eplf(_ line: [Unicode.Scalar]) -> RemoteEntry? {
        guard let tab = line.firstIndex(of: "\t") else {
            return nil
        }
        var entry = RemoteEntry(name: text(line[(tab + 1)...]), isDirectory: false)
        // Empty facts are left out by the split, so every fact has a kind.
        for fact in line[1..<tab].split(separator: ",") {
            let value = text(fact.dropFirst())
            switch fact.first {
            case "/":
                entry.isDirectory = true

            case "s":
                entry.size = size(Substring(value))

            case "m":
                // Seconds since 1970; anything else, or a time beyond the year 9999, is no date.
                if value.utf8.count <= 12, let seconds = Int64(value), (0...253_402_300_799).contains(seconds) {
                    entry.modified = Date(timeIntervalSince1970: TimeInterval(seconds))
                }

            case "u" where value.hasPrefix("p"):
                entry.permissions = UInt16(value.dropFirst(), radix: 8).map { $0 & 0o7777 }

            default:
                break
            }
        }
        return entry
    }
}
