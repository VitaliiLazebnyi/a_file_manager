import AFMKernel
public import Foundation

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
    /// How the letters of a run of text are cased, as the switches `[U] [L] [F] [f] [n]` set it.
    private enum Case {
        /// `[f]`: title case, the small words of English titles kept small.
        case englishTitle
        /// `[L]`: lower case.
        case lower
        /// `[n]`: as typed or as the placeholder gives it.
        case original
        /// `[F]`: every word starts with a capital.
        case title
        /// A counter's text, which no switch changes.
        case untouched
        /// `[U]`: upper case.
        case upper
    }

    /// The number a counter `[C]` stands for in one name.
    private struct Number {
        /// The number; nil for a name without one (the plain name of the optional digit).
        let value: Int?
        /// Whether the name is the first of a range or the plain name of the optional digit: with text
        /// around it, a counter there gives nothing.
        let isFirst: Bool
        /// The width the number is padded to with zeros, unless the counter gives its own.
        let width: Int
    }

    /// One expansion of a mask into a name: the runs of text so far, each with its case, and the
    /// switches in force.
    private struct Expansion {
        /// The switches that set the case of what follows.
        static let caseSwitches: [String: Case] = [
            "U": .upper, "L": .lower, "F": .title, "f": .englishTitle, "n": .original
        ]

        let context: Context
        let dates: DateTexts
        let number: Number
        var runs: [(text: String, mode: Case)] = []
        var mode = Case.original
        /// The moment the date and time placeholders show; a time switch moves it.
        var moment: Date

        /// The name: the runs in their cases, without spaces at either end.
        var name: String {
            runs.map { run in cased(run.text, run.mode) }.joined().trimmingCharacters(in: .whitespaces)
        }

        init(context: Context, dates: DateTexts, number: Number) {
            self.context = context
            self.dates = dates
            self.number = number
            moment = context.now
        }

        /// Adds text in the case in force, or in `forced`.
        mutating func emit(_ text: String, as forced: Case? = nil) {
            guard !text.isEmpty else {
                return
            }
            let runMode = forced ?? mode
            if let last = runs.last, last.mode == runMode {
                runs[runs.count - 1].text += text
            } else {
                runs.append((text, runMode))
            }
        }

        /// Adds what the placeholder `body` stands for, or takes the switch it is.
        mutating func apply(_ body: String) throws {
            if let switched = Self.caseSwitches[body] {
                mode = switched
                return
            }
            switch body {
            case "[", "]":
                emit(body)

            case "X", "X+":
                let text = clipboardText(context.clipboard ?? "")
                if text.isEmpty, body == "X" { throw Failure.emptyClipboard }
                emit(text)

            default:
                applyValue(body)
            }
        }

        /// Adds the value of a counter, a date, a part of a name or a variable; a placeholder that
        /// is none of them stays as typed.
        private mutating func applyValue(_ body: String) {
            if let counter = Placeholder.counter(body) {
                // With text around it, the first name of a range (and the plain name of
                // the optional digit) carries no number at all.
                guard let value = number.value, !(number.isFirst && counter.hasAffix) else {
                    return
                }
                let digits = String(value)
                let padded =
                    String(repeating: "0", count: max(0, (counter.width ?? number.width) - digits.count)) + digits
                emit(counter.prefix + padded + counter.suffix, as: .untouched)
            } else if let shifted = Placeholder.timeSwitch(body, from: context.now, context.calendar) {
                moment = shifted
            } else if let text = Placeholder.dateText(body, moment, context.calendar, dates) {
                emit(text)
            } else if let text = Placeholder.namePart(body, context) {
                emit(text)
            } else {
                emit("[" + body + "]")
            }
        }
    }

    /// Every name the text asks for, in the order they are to be created. `quotedLists` also
    /// reads `"a b.txt" "c.txt"` as several names (New file).
    public static func names(from text: String, context: Context, quotedLists: Bool = false) throws -> [String] {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard typed.hasPrefix("<") else {
            return plainNames(typed, quotedLists: quotedLists)
        }
        var mask = String(typed.dropFirst())
        // One set of date formatters for all the names of this text: making one costs more
        // than everything else an expansion does.
        let dates = DateTexts(context.calendar)
        if let range = leadingRange(&mask) {
            let width = String(range.upperBound).count
            return
                try range.map { counter in
                    let number = Number(value: counter, isFirst: counter == range.lowerBound, width: width)
                    return try expand(mask, context, dates, number)
                }
                .filter { !$0.isEmpty }
        }
        return try mask.split(separator: "|")
            .map(String.init)
            .compactMap { piece -> String? in
                let part = piece.trimmingCharacters(in: .whitespaces)
                guard !part.isEmpty else {
                    return nil
                }
                return try name(part, context, dates)
            }
    }

    /// The name one part of a mask gives; nil when it comes to nothing.
    ///
    /// With a counter it is the optional digit: the name without a number, then with 2, 3, … until
    /// one is free.
    private static func name(_ part: String, _ context: Context, _ dates: DateTexts) throws -> String? {
        let plain = try expand(part, context, dates, Number(value: nil, isFirst: true, width: 1))
        guard hasCounter(part) else {
            // A mask that comes to nothing (only a switch such as `[T2+1D]`) names nothing.
            return plain.isEmpty ? nil : plain
        }
        if !plain.isEmpty, !context.exists(plain) {
            return plain
        }
        for counter in 2...9_999 {
            let name = try expand(part, context, dates, Number(value: counter, isFirst: false, width: 1))
            if !name.isEmpty, !context.exists(name) {
                return name
            }
        }
        throw Failure.noFreeName(plain)
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

    /// The names of a text without placeholders: split at `|`, and with `quotedLists` at the quotes too.
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
        guard let close = mask.firstIndex(of: ">") else {
            return nil
        }
        let bounds = mask[..<close].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let first = Int(bounds[0]), let last = Int(bounds[1]), first >= 0, first <= last,
            last - first < 100_000
        else { return nil }
        mask = String(mask[mask.index(after: close)...])
        return first...last
    }

    /// Whether the mask holds a counter `[C]`.
    private static func hasCounter(_ mask: String) -> Bool {
        brackets(in: mask).contains { Placeholder.counter($0) != nil }
    }

    /// The texts between the brackets of the mask's placeholders, in their order.
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
        if text.hasPrefix("]]") {
            return text.index(after: text.startIndex)
        }
        var quoted = false
        return text.indices.first { index in
            if text[index] == "\"" { quoted.toggle() }
            return text[index] == "]" && !quoted
        }
    }

    /// The name `mask` gives with the counter at `number`.
    private static func expand(_ mask: String, _ context: Context, _ dates: DateTexts, _ number: Number)
        throws -> String
    {
        var expansion = Expansion(context: context, dates: dates, number: number)
        var rest = Substring(mask)
        while let open = rest.firstIndex(of: "[") {
            expansion.emit(String(rest[..<open]))
            let after = rest[rest.index(after: open)...]
            guard let close = closingBracket(after) else {
                rest = rest[open...]
                break
            }
            rest = after[after.index(after: close)...]
            try expansion.apply(String(after[..<close]))
        }
        expansion.emit(String(rest))
        return expansion.name
    }

    /// What `[X]` puts into a name: the first line of the clipboard, as one part of a name.
    ///
    /// Whatever would make it more than that is replaced: the characters no name may hold, a `/`
    /// (it would nest folders nobody typed), a leading `~`, and a text that is only dots (`..`
    /// would lead out of the folder).
    internal static func clipboardText(_ clipboard: String) -> String {
        let line = clipboard.prefix { !$0.isNewline }
        var text = String(
            line.unicodeScalars.map { scalar -> Character in
                "*?:|\"<>/\\".unicodeScalars.contains(scalar) || scalar.value < 0x20 || scalar.value == 0x7F
                    ? "_" : Character(scalar)
            }
        )
        .trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("~") { text = "_" + text.dropFirst() }
        if !text.isEmpty, text.allSatisfy({ $0 == "." }) { text = String(repeating: "_", count: text.count) }
        return text
    }

    /// The text in the case `mode` asks for.
    private static func cased(_ text: String, _ mode: Case) -> String {
        switch mode {
        case .original, .untouched:
            return text

        case .upper:
            return text.uppercased()

        case .lower:
            return text.lowercased()

        case .title, .englishTitle:
            let small: Set<String> =
                mode == .title
                ? []
                : [
                    "a", "an", "the", "at", "by", "for", "in", "of", "on", "to", "from", "up", "and", "as",
                    "but", "or", "nor", "yet", "so", "vs"
                ]
            var words = text.components(separatedBy: " ")
            let real = words.indices.filter { index in !words[index].isEmpty }
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
}
