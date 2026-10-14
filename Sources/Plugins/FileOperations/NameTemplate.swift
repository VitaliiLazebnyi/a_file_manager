import AFMKernel
import Foundation

/// The names typed into New folder (F7) and New file (Shift+F4): several at once, nested,
/// and, when the text starts with `<`, with placeholders and counter ranges (spec 07 › New
/// folder › Names, Counter ranges; 18 › Rename and new-folder placeholders).
///
///     a/b/c | other                 several names, each may be nested
///     <[Y]-[M]-[D] downloads        2026-10-12 downloads
///     <Copy of [N]                  Copy of <name under the cursor>
///     <1-10>[C]                     01 … 10
///     <1-3>test[" ("C")"]           test, test (2), test (3)
///     <test[C]                      the first free one of test, test2, test3, …
///
/// Supported placeholders: `[N] [E] [A] [P] [G] [S]` with the range forms of the spec
/// (`[N2-5]`, `[N2,3]`, `[N-3-]`, `[N02-9]`), the date and time letters `Y y M D h H m s v i d t`
/// alone or several in one bracket (`[YMD]`, `[Y-M-D]`), the time switches `[T1]`…`[T4]` with
/// offsets (`[T2+1D]`; every source is the moment the dialog was opened), the case switches
/// `[U] [L] [F] [f] [n]`, `[C]` with a width and quoted text around it, `[%VAR%]`, `[X]`,
/// `[X+]`, `[[]` and `[]]`. Content-plugin fields (`[=…]`) are not supported and stay as typed.
///
/// Pure: everything it needs to know comes in through `Context`. Usable on any thread.
public enum NameTemplate {
    public struct Context {
        /// The item under the cursor: its name with extension; empty on `[..]`.
        public var cursorName = ""
        public var cursorIsFolder = false
        public var cursorSize: Int64 = 0
        /// The folder the panel shows (for `[P]`) and the one above it (for `[G]`).
        public var parentName = ""
        public var grandparentName = ""
        /// The moment the dialog was opened.
        public var now = Date()
        public var calendar = Calendar.current
        public var clipboard: String?
        public var environment: [String: String] = ProcessInfo.processInfo.environment
        /// Whether a name is taken already, for the optional digit `[C]`. May touch a file system.
        public var exists: (String) -> Bool = { _ in false }

        public init() {}
    }

    public enum Failure: LocalizedError, Equatable {
        case emptyClipboard
        case noFreeName(String)

        public var errorDescription: String? {
            switch self {
            case .emptyClipboard: return "The clipboard holds no text for [X]."
            case .noFreeName(let name): return "No free name was found for \(name)."
            }
        }
    }

    /// Every name the text asks for, in the order they are to be created. `quotedLists` also
    /// reads `"a b.txt" "c.txt"` as several names (New file).
    public static func names(from text: String, context: Context, quotedLists: Bool = false) throws -> [String] {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("<") else { return plainNames(text, quotedLists: quotedLists) }
        var mask = String(text.dropFirst())
        // One set of date formatters for all the names of this text: making one costs more
        // than everything else an expansion does.
        let dates = DateTexts(context.calendar)
        if let range = leadingRange(&mask) {
            let width = String(range.upperBound).count
            return try range.map {
                try expand(mask, context, dates, counter: $0, isFirst: $0 == range.lowerBound, width: width)
            }.filter { !$0.isEmpty }
        }
        return try mask.split(separator: "|").map(String.init).compactMap { part -> String? in
            let part = part.trimmingCharacters(in: .whitespaces)
            guard !part.isEmpty else { return nil }
            guard hasCounter(part) else {
                // A mask that comes to nothing (only a switch such as `[T2+1D]`) names nothing.
                let name = try expand(part, context, dates, counter: nil, isFirst: true, width: 1)
                return name.isEmpty ? nil : name
            }
            // The optional digit: the name without a number, then with 2, 3, … until one is free.
            let plain = try expand(part, context, dates, counter: nil, isFirst: true, width: 1)
            if !plain.isEmpty, !context.exists(plain) { return plain }
            for counter in 2...9_999 {
                let name = try expand(part, context, dates, counter: counter, isFirst: false, width: 1)
                if !name.isEmpty, !context.exists(name) { return name }
            }
            throw Failure.noFreeName(plain)
        }
    }

    /// The formatters behind `[d]` and `[t]`, made once per text and only when asked for.
    private final class DateTexts {
        private let calendar: Calendar
        private var formatters: [Character: DateFormatter] = [:]

        init(_ calendar: Calendar) { self.calendar = calendar }

        func text(_ letter: Character, _ moment: Date) -> String {
            let formatter =
                formatters[letter]
                ?? {
                    let formatter = DateFormatter()
                    formatter.calendar = calendar
                    formatter.timeZone = calendar.timeZone
                    formatter.dateStyle = letter == "d" ? .short : .none
                    formatter.timeStyle = letter == "t" ? .short : .none
                    formatters[letter] = formatter
                    return formatter
                }()
            return formatter.string(from: moment).replacingOccurrences(of: "/", with: "-").replacingOccurrences(
                of: ":", with: ".")
        }
    }

    /// The first and the last name of a counter range, as the dialog previews them; nil when
    /// the text is not a range.
    public static func rangePreview(_ text: String, context: Context) -> (first: String, last: String)? {
        guard text.hasPrefix("<"), let names = try? names(from: text, context: context), names.count > 1,
            let first = names.first, let last = names.last
        else { return nil }
        var mask = String(text.dropFirst())
        return leadingRange(&mask) == nil ? nil : (first, last)
    }

    private static func plainNames(_ text: String, quotedLists: Bool) -> [String] {
        var names: [String] = []
        var current = ""
        var quoted = false
        func finish() {
            let name = current.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { names.append(name) }
            current = ""
        }
        for character in text {
            if character == "\"", quotedLists {
                quoted.toggle()
                if !quoted { finish() }
            } else if character == "|", !quoted {
                finish()
            } else {
                current.append(character)
            }
        }
        finish()
        return names
    }

    /// `1-10>` at the very start of the mask; removes it.
    private static func leadingRange(_ mask: inout String) -> ClosedRange<Int>? {
        guard let close = mask.firstIndex(of: ">") else { return nil }
        let bounds = mask[..<close].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let from = Int(bounds[0]), let to = Int(bounds[1]), from >= 0, from <= to,
            to - from < 100_000
        else { return nil }
        mask = String(mask[mask.index(after: close)...])
        return from...to
    }

    private static func hasCounter(_ mask: String) -> Bool {
        brackets(in: mask).contains { counterParts($0) != nil }
    }

    private static func brackets(in mask: String) -> [String] {
        var found: [String] = []
        var rest = Substring(mask)
        while let open = rest.firstIndex(of: "[") {
            let after = rest[rest.index(after: open)...]
            guard let close = closingBracket(after) else { break }
            found.append(String(after[..<close]))
            rest = after[after.index(after: close)...]
        }
        return found
    }

    /// The `]` that ends a placeholder; `[]]` holds one itself.
    private static func closingBracket(_ text: Substring) -> Substring.Index? {
        if text.hasPrefix("]]") { return text.index(after: text.startIndex) }
        var quoted = false
        for index in text.indices {
            if text[index] == "\"" { quoted.toggle() }
            if text[index] == "]", !quoted { return index }
        }
        return nil
    }

    /// No name is longer than this, so no width of a counter or a range may be either.
    private static let maxWidth = 255
    /// Positions in a range are cut to this; no value a range is applied to is that long.
    private static let positionLimit = 1 << 20

    private enum Case { case original, upper, lower, title, englishTitle, untouched }

    private static func expand(
        _ mask: String, _ context: Context, _ dates: DateTexts, counter: Int?, isFirst: Bool, width: Int
    ) throws -> String {
        var runs: [(text: String, mode: Case)] = []
        var mode = Case.original
        var moment = context.now
        func emit(_ text: String, as forced: Case? = nil) {
            guard !text.isEmpty else { return }
            let mode = forced ?? mode
            if let last = runs.last, last.mode == mode {
                runs[runs.count - 1].text += text
            } else {
                runs.append((text, mode))
            }
        }
        var rest = Substring(mask)
        while let open = rest.firstIndex(of: "[") {
            emit(String(rest[..<open]))
            let after = rest[rest.index(after: open)...]
            guard let close = closingBracket(after) else {
                rest = rest[open...]
                break
            }
            let body = String(after[..<close])
            rest = after[after.index(after: close)...]
            switch body {
            case "[": emit("[")
            case "]": emit("]")
            case "U": mode = .upper
            case "L": mode = .lower
            case "F": mode = .title
            case "f": mode = .englishTitle
            case "n": mode = .original

            case "X", "X+":
                let text = clipboardText(context.clipboard ?? "")
                if text.isEmpty, body == "X" { throw Failure.emptyClipboard }
                emit(text)

            default:
                if let parts = counterParts(body) {
                    // With text around it, the first name of a range (and the plain name of
                    // the optional digit) carries no number at all.
                    guard let counter, !(isFirst && parts.hasAffix) else { break }
                    let digits = String(counter)
                    let padded = String(repeating: "0", count: max(0, (parts.width ?? width) - digits.count)) + digits
                    emit(parts.prefix + padded + parts.suffix, as: .untouched)
                } else if let shifted = timeSwitch(body, from: context.now, context.calendar) {
                    moment = shifted
                } else if let text = dateText(body, moment, context.calendar, dates) {
                    emit(text)
                } else if let text = namePart(body, context) {
                    emit(text)
                } else {
                    emit("[" + body + "]")
                }
            }
        }
        emit(String(rest))
        return runs.map { cased($0.text, $0.mode) }.joined().trimmingCharacters(in: .whitespaces)
    }

    /// What `[X]` puts into a name: the first line of the clipboard, as one part of a name.
    /// Whatever would make it more than that is replaced: the characters no name may hold, a
    /// `/` (it would nest folders nobody typed), a leading `~`, and a text that is only dots
    /// (`..` would lead out of the folder).
    static func clipboardText(_ clipboard: String) -> String {
        let line = clipboard.components(separatedBy: .newlines).first ?? ""
        var text = String(
            line.unicodeScalars.map { scalar -> Character in
                "*?:|\"<>/\\".unicodeScalars.contains(scalar) || scalar.value < 0x20 || scalar.value == 0x7F
                    ? "_" : Character(scalar)
            }
        ).trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("~") { text = "_" + text.dropFirst() }
        if !text.isEmpty, text.allSatisfy({ $0 == "." }) { text = String(repeating: "_", count: text.count) }
        return text
    }

    private static func cased(_ text: String, _ mode: Case) -> String {
        switch mode {
        case .original, .untouched: return text
        case .upper: return text.uppercased()
        case .lower: return text.lowercased()

        case .title, .englishTitle:
            let small: Set<String> =
                mode == .title
                ? []
                : [
                    "a", "an", "the", "at", "by", "for", "in", "of", "on", "to", "from", "up", "and", "as",
                    "but", "or", "nor", "yet", "so", "vs"
                ]
            var words = text.components(separatedBy: " ")
            let real = words.indices.filter { !words[$0].isEmpty }
            for index in real {
                let lower = words[index].lowercased()
                // The small words of a title stay small, except as its first or last word.
                if small.contains(lower), index != real.first, index != real.last {
                    words[index] = lower
                } else {
                    words[index] = lower.prefix(1).uppercased() + lower.dropFirst()
                }
            }
            return words.joined(separator: " ")
        }
    }

    /// `C`, `C:3`, `C10+5:3`, `" ("C")"`: the width and the text around the number. In a new
    /// name the number comes from the range, so an inline start and step are read and ignored.
    private static func counterParts(_ body: String) -> (prefix: String, suffix: String, width: Int?, hasAffix: Bool)? {
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
        guard core.hasPrefix("C") else { return nil }
        let options = core.dropFirst()
        guard options.allSatisfy({ $0.isNumber || $0 == "+" || $0 == "-" || $0 == ":" || $0 == "a" }) else {
            return nil
        }
        let width = options.split(separator: ":", omittingEmptySubsequences: false).dropFirst().first.flatMap {
            Int($0)
        }.map { min(max($0, 0), maxWidth) }
        return (prefix, suffix, width, body.contains("\""))
    }

    /// `T1`…`T4`, optionally with an offset such as `+60m` or `-1D`.
    private static func timeSwitch(_ body: String, from now: Date, _ calendar: Calendar) -> Date? {
        guard body.count >= 2, body.hasPrefix("T"), let source = body.dropFirst().first, "1234".contains(source) else {
            return nil
        }
        let offset = body.dropFirst(2)
        if offset.isEmpty { return now }
        guard let unit = offset.last, let amount = Int(offset.dropLast()) else { return nil }
        let components: [Character: Calendar.Component] = [
            "s": .second, "m": .minute, "h": .hour, "D": .day, "M": .month, "Y": .year
        ]
        guard let component = components[unit] else { return nil }
        return calendar.date(byAdding: component, value: amount, to: now)
    }

    /// A bracket made of date and time letters, with any separators between them.
    private static func dateText(_ body: String, _ moment: Date, _ calendar: Calendar, _ dates: DateTexts) -> String? {
        let letters = "YyMDhHmsvidt"
        guard body.contains(where: { letters.contains($0) }),
            body.allSatisfy({ letters.contains($0) || "-_. ,1".contains($0) })
        else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: moment)
        let (year, hour) = (parts.year ?? 0, parts.hour ?? 0)
        func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        var text = ""
        var characters = Array(body)[...]
        while let letter = characters.popFirst() {
            switch letter {
            case "Y": text += String(format: "%04d", year)
            case "y": text += two(year % 100)
            case "M": text += two(parts.month)
            case "D": text += two(parts.day)
            case "h": text += two(hour)
            case "H": text += two(hour % 12 == 0 ? 12 : hour % 12)
            case "m": text += two(parts.minute)
            case "s": text += two(parts.second)
            case "v": text += String(format: "%03d", (parts.nanosecond ?? 0) / 1_000_000)

            case "i":
                let short = characters.first == "1"
                if short { characters.removeFirst() }
                text += hour < 12 ? (short ? "a" : "am") : (short ? "p" : "pm")

            case "d", "t":
                text += dates.text(letter, moment)

            default: text.append(letter)
            }
        }
        return text
    }

    /// `N`, `E`, `A`, `P`, `G`, `S` and `%VAR%`, each with an optional range.
    private static func namePart(_ body: String, _ context: Context) -> String? {
        if body.hasPrefix("%"), let end = body.dropFirst().firstIndex(of: "%") {
            let value = context.environment[String(body[body.index(after: body.startIndex)..<end])] ?? ""
            return slice(value, String(body[body.index(after: end)...]))
        }
        guard let letter = body.first else { return nil }
        let split = context.cursorIsFolder ? (base: context.cursorName, ext: "") : FileItem.split(context.cursorName)
        let value: String
        switch letter {
        case "N": value = split.base
        case "E": value = split.ext
        case "A": value = context.cursorName
        case "P": value = context.parentName
        case "G": value = context.grandparentName
        case "S": value = String(context.cursorSize)
        default: return nil
        }
        return slice(value, String(body.dropFirst()))
    }

    /// Applies a range (spec 18 › Range forms) to a value; nil when `range` is not one.
    private static func slice(_ value: String, _ range: String) -> String? {
        if range.isEmpty { return value }
        var text = Substring(range)
        var pad: Character?
        if let first = text.first, first == "0" || first == " ", text.count > 1 {
            pad = first
            text = text.dropFirst()
        }
        let characters = Array(value)
        /// A position counted from 1, or from the end when negative, as an index from 0.
        /// No position is larger than `positionLimit`: beyond it lies nothing, and the sums
        /// below stay far from the ends of `Int`.
        func position(_ text: inout Substring, fromEnd: Bool = false) -> Int? {
            let negative = text.hasPrefix("-") || fromEnd
            if text.hasPrefix("-") { text = text.dropFirst() }
            let digits = text.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, digits.count <= 18, let typed = Int(digits), typed > 0 else { return nil }
            let number = min(typed, positionLimit)
            text = text.dropFirst(digits.count)
            return negative ? characters.count - number : number - 1
        }
        let countsFromEnd = text.hasPrefix("-")
        guard let start = position(&text) else { return nil }
        var end = start
        var width: Int?
        if text.hasPrefix(",") {
            // A length is a count: never negative, and no longer than a name can be.
            let digits = text.dropFirst()
            guard !digits.isEmpty, digits.count <= 18, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                let typed = Int(digits)
            else { return nil }
            let length = min(typed, maxWidth)
            end = start + length - 1
            width = length
        } else if text.hasPrefix("-") {
            text = text.dropFirst()
            if text.isEmpty {
                end = characters.count - 1
            } else {
                // After a start counted from the end, the end is counted from there too: `[N-8-5]`.
                guard let last = position(&text, fromEnd: countsFromEnd), text.isEmpty else { return nil }
                end = last
                width = last - start + 1
            }
        } else if !text.isEmpty {
            return nil
        }
        let (from, to) = (max(0, start), min(characters.count - 1, end))
        let part = from <= to ? String(characters[from...to]) : ""
        guard let pad, let width = width.map({ min($0, maxWidth) }), part.count < width else { return part }
        return String(repeating: String(pad), count: width - part.count) + part
    }
}
