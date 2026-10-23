import AFMKernel
import Foundation

/// The readers of the placeholders that stand for a value: counters, time switches, dates and parts of names.
extension NameTemplate {
    /// A counter `[C]` as a new name uses it: the width and the text around the number.
    internal struct Counter: Equatable {
        /// The text before the number (`" ("` in `[" ("C")"]`).
        internal var prefix: String
        /// The text after the number.
        internal var suffix: String
        /// The width the number is padded to with zeros; nil leaves it to the range.
        internal var width: Int?
        /// Whether text in quotes stands around the number.
        internal var hasAffix: Bool
    }

    /// The formatters behind `[d]` and `[t]`, made once per text and only when asked for.
    ///
    /// Used by one expansion, on one thread.
    internal final class DateTexts {
        /// The calendar the formatters show dates and times in.
        private let calendar: Calendar
        /// The formatters made so far, by letter.
        private var formatters: [Character: DateFormatter] = [:]

        /// Formatters for `calendar`, none made yet.
        internal init(_ calendar: Calendar) { self.calendar = calendar }

        /// The short date (`d`) or time (`t`) of `moment`, with `/` and `:` replaced, which no name may hold.
        internal func text(_ letter: Character, _ moment: Date) -> String {
            let formatter = formatters[letter] ?? make(letter)
            return formatter.string(from: moment)
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: ".")
        }

        /// Makes the formatter for `letter` and keeps it.
        private func make(_ letter: Character) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateStyle = letter == "d" ? .short : .none
            formatter.timeStyle = letter == "t" ? .short : .none
            formatters[letter] = formatter
            return formatter
        }

        deinit {
            // Nothing to release.
        }
    }

    /// Reads one placeholder (the text between its brackets) into what it stands for; nil for one it is not.
    ///
    /// Pure, like the template; the date formatters come from the caller.
    internal enum Placeholder {
        /// No name is longer than this, so no width of a counter or a range may be either.
        private static let maxWidth = 255
        /// Positions in a range are cut to this; no value a range is applied to is that long.
        private static let positionLimit = 1 << 20
        /// The date and time letters that stand for a number of two digits, and the part of the date each shows.
        private static let twoDigitFields: [Character: Calendar.Component] = [
            "M": .month, "D": .day, "h": .hour, "m": .minute, "s": .second
        ]

        /// `C`, `C:3`, `C10+5:3`, `" ("C")"`: the width and the text around the number.
        ///
        /// In a new name the number comes from the range, so an inline start and step are read and
        /// ignored.
        internal static func counter(_ body: String) -> Counter? {
            var core = body
            var prefix = ""
            var suffix = ""
            if core.hasPrefix("\""), let end = core.dropFirst().firstIndex(of: "\"") {
                prefix = String(core[core.index(after: core.startIndex)..<end])
                core = String(core[core.index(after: end)...])
            }
            if core.hasSuffix("\""), let start = core.dropLast().lastIndex(of: "\"") {
                suffix = String(core[core.index(after: start)..<core.index(before: core.endIndex)])
                core = String(core[..<start])
            }
            guard core.hasPrefix("C") else {
                return nil
            }
            let options = core.dropFirst()
            guard options.allSatisfy({ $0.isNumber || $0 == "+" || $0 == "-" || $0 == ":" || $0 == "a" }) else {
                return nil
            }
            let width = options.split(separator: ":", omittingEmptySubsequences: false)
                .dropFirst()
                .first
                .flatMap { Int($0) }
                .map { min(max($0, 0), maxWidth) }
            return Counter(prefix: prefix, suffix: suffix, width: width, hasAffix: body.contains("\""))
        }

        /// `T1`…`T4`, optionally with an offset such as `+60m` or `-1D`.
        internal static func timeSwitch(_ body: String, from now: Date, _ calendar: Calendar) -> Date? {
            guard body.count >= 2, body.hasPrefix("T"), let source = body.dropFirst().first, "1234".contains(source)
            else {
                return nil
            }
            let offset = body.dropFirst(2)
            if offset.isEmpty {
                return now
            }
            guard let unit = offset.last, let amount = Int(offset.dropLast()) else {
                return nil
            }
            let components: [Character: Calendar.Component] = [
                "s": .second, "m": .minute, "h": .hour, "D": .day, "M": .month, "Y": .year
            ]
            guard let component = components[unit] else {
                return nil
            }
            return calendar.date(byAdding: component, value: amount, to: now)
        }

        /// A bracket made of date and time letters, with any separators between them.
        internal static func dateText(_ body: String, _ moment: Date, _ calendar: Calendar, _ dates: DateTexts)
            -> String?
        {
            let letters = "YyMDhHmsvidt"
            guard body.contains(where: { letters.contains($0) }),
                body.allSatisfy({ letters.contains($0) || "-_. ,1".contains($0) })
            else { return nil }
            var text = ""
            var characters = ArraySlice(body)
            while let letter = characters.popFirst() {
                switch letter {
                case "i":
                    let short = characters.first == "1"
                    if short { characters.removeFirst() }
                    let morning = calendar.component(.hour, from: moment) < 12
                    text += morning ? (short ? "a" : "am") : (short ? "p" : "pm")

                case "d", "t":
                    text += dates.text(letter, moment)

                default:
                    text += dateField(letter, moment, calendar) ?? String(letter)
                }
            }
            return text
        }

        /// The number one date or time letter stands for (`Y` 2026, `H` 03, `v` 042); nil for a separator.
        private static func dateField(_ letter: Character, _ moment: Date, _ calendar: Calendar) -> String? {
            func part(_ component: Calendar.Component) -> Int { calendar.component(component, from: moment) }
            func two(_ value: Int) -> String { String(format: "%02d", value) }
            switch letter {
            case "Y":
                return String(format: "%04d", part(.year))

            case "y":
                return two(part(.year) % 100)

            case "H":
                let hour = part(.hour)
                return two(hour.isMultiple(of: 12) ? 12 : hour % 12)

            case "v":
                return String(format: "%03d", part(.nanosecond) / 1_000_000)

            default:
                return twoDigitFields[letter].map { two(part($0)) }
            }
        }

        /// `N`, `E`, `A`, `P`, `G`, `S` and `%VAR%`, each with an optional range.
        internal static func namePart(_ body: String, _ context: Context) -> String? {
            if body.hasPrefix("%"), let end = body.dropFirst().firstIndex(of: "%") {
                let value = context.environment[String(body[body.index(after: body.startIndex)..<end])] ?? ""
                return slice(value, String(body[body.index(after: end)...]))
            }
            guard let letter = body.first else {
                return nil
            }
            let split =
                context.cursorIsFolder ? (base: context.cursorName, ext: "") : FileItem.split(context.cursorName)
            let value: String
            switch letter {
            case "N":
                value = split.base

            case "E":
                value = split.ext

            case "A":
                value = context.cursorName

            case "P":
                value = context.parentName

            case "G":
                value = context.grandparentName

            case "S":
                value = String(context.cursorSize)

            default:
                return nil
            }
            return slice(value, String(body.dropFirst()))
        }

        /// Applies a range (spec 18 › Range forms) to a value; nil when `range` is not one.
        private static func slice(_ value: String, _ range: String) -> String? {
            if range.isEmpty {
                return value
            }
            var text = Substring(range)
            var pad: Character?
            if let first = text.first, first == "0" || first == " ", text.count > 1 {
                pad = first
                text = text.dropFirst()
            }
            let characters = Array(value)
            let countsFromEnd = text.hasPrefix("-")
            guard let start = position(&text, count: characters.count, fromEnd: false) else {
                return nil
            }
            var end = start
            var width: Int?
            if text.hasPrefix(",") {
                guard let length = length(text.dropFirst()) else {
                    return nil
                }
                end = start + length - 1
                width = length
            } else if text.hasPrefix("-") {
                text = text.dropFirst()
                if text.isEmpty {
                    end = characters.count - 1
                } else {
                    // After a start counted from the end, the end is counted from there too: `[N-8-5]`.
                    guard let last = position(&text, count: characters.count, fromEnd: countsFromEnd), text.isEmpty
                    else {
                        return nil
                    }
                    end = last
                    width = last - start + 1
                }
            } else if !text.isEmpty {
                return nil
            }
            let (lower, upper) = (max(0, start), min(characters.count - 1, end))
            let part = lower <= upper ? String(characters[lower...upper]) : ""
            guard let pad, let padded = width.map({ min($0, maxWidth) }), part.count < padded else {
                return part
            }
            return String(repeating: String(pad), count: padded - part.count) + part
        }

        /// A position counted from 1, or from the end when negative, as an index from 0 into a value
        /// of `count` characters; reads it off the front of `text`.
        ///
        /// No position is larger than `positionLimit`: beyond it lies nothing, and the sums of
        /// `slice` stay far from the ends of `Int`.
        private static func position(_ text: inout Substring, count: Int, fromEnd: Bool) -> Int? {
            let negative = text.hasPrefix("-") || fromEnd
            if text.hasPrefix("-") { text = text.dropFirst() }
            let digits = text.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, digits.count <= 18, let typed = Int(digits), typed > 0 else {
                return nil
            }
            let number = min(typed, positionLimit)
            text = text.dropFirst(digits.count)
            return negative ? count - number : number - 1
        }

        /// The length after the comma of a range: a count, never negative and no longer than a name can be.
        private static func length(_ digits: Substring) -> Int? {
            guard !digits.isEmpty, digits.count <= 18, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                let typed = Int(digits)
            else { return nil }
            return min(typed, maxWidth)
        }
    }
}
