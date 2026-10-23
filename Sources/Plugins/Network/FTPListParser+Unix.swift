internal import Foundation

/// The Unix `ls -l` format of LIST.
extension FTPListParser {
    /// A line of Unix `ls -l` output, read by hand, token by token.
    ///
    /// What every `ls -l` variant ends with, in the three ways servers write the date:
    /// `<size> <month> <day> <year or time> <name>`, the same with the day before the month (as
    /// some European servers print it), and `<size> 2024-01-31 12:34 <name>`
    /// (`ls --time-style=long-iso`, some newer servers). The first place of the line that reads as one
    /// of them is taken, the forms tried in this order.
    internal struct UnixLine {
        /// Month abbreviations in the languages servers use, lower case, to the month's number.
        private static let months: [String: Int] = {
            let names: [[String]] = [
                ["jan", "ene", "gen", "janv"], ["feb", "fev", "fév", "févr"], ["mar", "mär", "mrz", "mars"],
                ["apr", "avr", "abr"],
                ["may", "mai", "mag", "mei"], ["jun", "juin", "giu"], ["jul", "juil", "lug"],
                ["aug", "aou", "aoû", "août", "ago"],
                ["sep", "sept", "set"], ["oct", "okt", "ott", "out"], ["nov"], ["dec", "dez", "déc", "dic"]
            ]
            var table: [String: Int] = [:]
            for (index, group) in names.enumerated() {
                for name in group { table[name] = index + 1 }
            }
            return table
        }()

        private let line: [Unicode.Scalar]
        /// The first ten scalars: the type and, when `hasMode`, the mode string.
        private let characters: [Unicode.Scalar]
        /// Whether the line starts with a full mode string (`-rwxr-xr-x`) rather than NetWare's `d [RWCEAFMS]`.
        private let hasMode: Bool
        private let now: Date
        private let calendar: Calendar

        /// The line, or nil when it does not start the way `ls -l` lines do; dates without a year are
        /// taken as the latest such date not after `now`, in `calendar`.
        internal init?(_ line: [Unicode.Scalar], now: Date, calendar: Calendar) {
            let start = Array(line.prefix(10))
            guard let type = start.first, "-dlbcpsDw".unicodeScalars.contains(type) else {
                return nil
            }
            // Either a full mode string (`-rwxr-xr-x`) or NetWare's `d [RWCEAFMS]`.
            let isModeString =
                start.count == 10 && start.dropFirst().allSatisfy { "-rwxsStTlL".unicodeScalars.contains($0) }
            guard isModeString || line.dropFirst().drop(while: { $0 == " " }).first == "[" else {
                return nil
            }
            (self.line, characters, hasMode, self.now, self.calendar) = (line, start, isModeString, now, calendar)
        }

        /// The runs between white space, as ranges of the line.
        private static func tokens(_ line: [Unicode.Scalar]) -> [Range<Int>] {
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

        /// The number a run of digits spells, when the token is nothing else and has as many digits as allowed.
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

        /// `12:34` or `12:34:56`, optionally with a fraction of a second, as hour, minute and (when given)
        /// second.
        private static func clockTime(_ token: ArraySlice<Unicode.Scalar>, allowsFraction: Bool) -> DateComponents? {
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
                return DateComponents(hour: hour, minute: minute)
            }
            guard let second = number(parts[2], digits: 2...2) else {
                return nil
            }
            return DateComponents(hour: hour, minute: minute, second: second)
        }

        /// The month a token names: three to five letters, with or without a full stop.
        private static func monthNumber(_ token: ArraySlice<Unicode.Scalar>) -> Int? {
            var letters = token
            if letters.last == "." { letters = letters.dropLast() }
            guard (3...5).contains(letters.count),
                letters.allSatisfy({ letter in
                    (letter.value >= 0x41 && letter.value <= 0x5A) || (letter.value >= 0x61 && letter.value <= 0x7A)
                        || (letter.value >= 0xC0 && letter.value <= 0x24F)
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

        /// The entry the line describes, or nil when no date and name can be found in it.
        internal func entry() -> RemoteEntry? {
            let type = characters[0]
            var entry = RemoteEntry(name: "", isDirectory: type == "d" || type == "D", isSymlink: type == "l")
            entry.isSpecial = "cbps".unicodeScalars.contains(type)
            let tokens = Self.tokens(line)
            guard var name = monthDayName(tokens, into: &entry) ?? isoName(tokens, into: &entry) else {
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

        /// The name after `<size> <month> <day> <year|time>`, or after the same with the day first; size
        /// and date go into `entry` when a name is found.
        private func monthDayName(_ tokens: [Range<Int>], into entry: inout RemoteEntry) -> String? {
            for dayFirst in [false, true] {
                for index in stride(from: 1, to: tokens.count - 2, by: 1) {
                    if let name = monthDayName(tokens, at: index, dayFirst: dayFirst, into: &entry) {
                        return name
                    }
                }
            }
            return nil
        }

        /// `monthDayName` for the date that starts at token `index`, the size ending the token before it.
        private func monthDayName(
            _ tokens: [Range<Int>],
            at index: Int,
            dayFirst: Bool,
            into entry: inout RemoteEntry
        ) -> String? {
            let (monthToken, dayToken) =
                dayFirst
                ? (line[tokens[index + 1]], line[tokens[index]]) : (line[tokens[index]], line[tokens[index + 1]])
            guard let month = Self.monthNumber(monthToken), let day = Self.dayNumber(dayToken, allowsStop: dayFirst),
                let size = Self.trailingSize(line[tokens[index - 1]])
            else { return nil }
            let last = line[tokens[index + 2]]
            var components = DateComponents()
            (components.month, components.day) = (month, day)
            let modified: Date?
            if let year = Self.number(last, digits: 4...4) {
                components.year = year
                modified = date(components, calendar: calendar)
            } else if let time = Self.clockTime(last, allowsFraction: false) {
                (components.hour, components.minute, components.second) = (time.hour, time.minute, time.second)
                modified = recent(components)
            } else {
                return nil
            }
            guard let found = rest(after: tokens[index + 2]) else {
                return nil
            }
            (entry.size, entry.modified) = (size, modified)
            return found
        }

        /// The name after `<size> 2024-01-31 12:34[:56][.789] [+0100]`; size and date go into `entry` when a
        /// name is found.
        private func isoName(_ tokens: [Range<Int>], into entry: inout RemoteEntry) -> String? {
            for index in stride(from: 1, to: tokens.count - 1, by: 1) {
                if let name = isoName(tokens, at: index, into: &entry) {
                    return name
                }
            }
            return nil
        }

        /// `isoName` for the date that is token `index`, the size ending the token before it.
        private func isoName(_ tokens: [Range<Int>], at index: Int, into entry: inout RemoteEntry) -> String? {
            let parts = line[tokens[index]].split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 3, let year = Self.number(parts[0], digits: 4...4),
                let month = Self.number(parts[1], digits: 2...2),
                let dayOfMonth = Self.number(parts[2], digits: 2...2),
                let time = Self.clockTime(line[tokens[index + 1]], allowsFraction: true),
                let size = Self.trailingSize(line[tokens[index - 1]])
            else { return nil }
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
            guard let found = rest(after: last) else {
                return nil
            }
            var components = DateComponents()
            (components.year, components.month, components.day) = (year, month, dayOfMonth)
            (components.hour, components.minute) = (time.hour, time.minute)
            (entry.size, entry.modified) = (size, date(components, calendar: calendar))
            return found
        }

        /// The name: everything after the one white space that follows the date.
        private func rest(after token: Range<Int>) -> String? {
            let start = token.upperBound + 1
            guard start < line.count else {
                return nil
            }
            return text(line[start...])
        }

        /// `ls` leaves out the year for the last six months: a date with a time and no year.
        private func recent(_ parts: DateComponents) -> Date? {
            var components = parts
            let thisYear = calendar.component(.year, from: now)
            components.year = thisYear
            guard let found = date(components, calendar: calendar) else {
                return nil
            }
            // A date without a year lies in the past; a day of slack covers the server's time zone.
            if found > now.addingTimeInterval(86_400) {
                components.year = thisYear - 1
                return date(components, calendar: calendar)
            }
            return found
        }
    }
}
