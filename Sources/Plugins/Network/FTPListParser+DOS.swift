internal import Foundation

/// The Windows/DOS `dir` format of LIST.
extension FTPListParser {
    /// A line of a Windows/DOS `dir` listing, read scalar by scalar from the start:
    /// `01-31-24  03:04PM       <DIR>          name` or `01-31-2024  15:04  1,234 name`.
    internal struct DOSLine {
        private let line: [Unicode.Scalar]
        /// Where reading has come to.
        private var position = 0

        private init(_ line: [Unicode.Scalar]) {
            self.line = line
        }

        /// The entry a `dir` line describes, or nil when the line is no such entry.
        ///
        /// The time is read in `calendar`, as the line gives no zone.
        internal static func entry(of line: [Unicode.Scalar], calendar: Calendar) -> RemoteEntry? {
            var reader = Self(line)
            return reader.entry(calendar: calendar)
        }

        /// Reads the date, the time, the size or kind, and the name, in this order.
        private mutating func entry(calendar: Calendar) -> RemoteEntry? {
            guard let components = dateAndTime() else {
                return nil
            }
            var entry = RemoteEntry(name: "", isDirectory: false)
            guard readKind(into: &entry), space() > 0, position < line.count else {
                return nil
            }
            entry.name = text(line[position...])
            entry.modified = date(components, calendar: calendar)
            return entry
        }

        /// `01-31-24  03:04PM` and what follows it up to the size or the kind, which must be white space.
        private mutating func dateAndTime() -> DateComponents? {
            guard let month = digits(2...2), separator(), let day = digits(2...2), separator(),
                var year = digits(2...4), space() > 0,
                var hour = digits(1...2), position < line.count, line[position] == ":"
            else { return nil }
            position += 1
            guard let minute = digits(2...2) else {
                return nil
            }
            var gap = space()
            if let marked = markedHour(hour) {
                hour = marked
                gap = space()
            }
            guard gap > 0 else {
                return nil
            }
            if year < 100 { year += year < 70 ? 2_000 : 1_900 }
            return DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        }

        /// The hour on the 24-hour clock when an AM or PM marker follows (and is read); nil when none does.
        private mutating func markedHour(_ hour: Int) -> Int? {
            guard position < line.count, "AaPp".unicodeScalars.contains(line[position]) else {
                return nil
            }
            let isAfternoon = line[position] == "P" || line[position] == "p"
            position += 1
            if position < line.count, line[position] == "M" || line[position] == "m" { position += 1 }
            if isAfternoon, hour < 12 {
                return hour + 12
            }
            if !isAfternoon, hour == 12 {
                return 0
            }
            return hour
        }

        /// `<DIR>` (or a link kind) or a size with thousands separators, into `entry`; false when it is neither.
        private mutating func readKind(into entry: inout RemoteEntry) -> Bool {
            let kindStart = position
            guard position < line.count, line[position] == "<" else {
                while position < line.count, isDigit(line[position]) || line[position] == "." || line[position] == "," {
                    position += 1
                }
                guard position > kindStart else {
                    return false
                }
                entry.size = size(Substring(text(ArraySlice(line[kindStart..<position].filter(isDigit)))))
                return true
            }
            while position < line.count, line[position] != ">", !isSpace(line[position]) { position += 1 }
            guard position < line.count, line[position] == ">" else {
                return false
            }
            position += 1
            let kind = text(line[kindStart..<position])
            guard ["<DIR>", "<JUNCTION>", "<SYMLINK>", "<SYMLINKD>"].contains(kind) else {
                return false
            }
            (entry.isDirectory, entry.isSymlink) = (true, kind != "<DIR>")
            return true
        }

        /// The number spelled by the digits at the reading place, read when there are as many as `range` allows.
        private mutating func digits(_ range: ClosedRange<Int>) -> Int? {
            var end = position
            while end < line.count, isDigit(line[end]) { end += 1 }
            guard range.contains(end - position) else {
                return nil
            }
            defer { position = end }
            return Int(text(line[position..<end]))
        }

        /// Reads a `-`, `/` or `.` between the numbers of a date; false when none is there.
        private mutating func separator() -> Bool {
            guard position < line.count, line[position] == "-" || line[position] == "/" || line[position] == "." else {
                return false
            }
            position += 1
            return true
        }

        /// Skips white space and tells how much there was.
        private mutating func space() -> Int {
            let start = position
            while position < line.count, isSpace(line[position]) { position += 1 }
            return position - start
        }
    }
}
