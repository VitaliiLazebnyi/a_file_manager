import Foundation

/// What a rename mask sees of one item.
///
/// The name may differ from the name on disk: after "next step" the computed names stand in for the
/// old ones (spec 09 › Result list).
internal struct RenameSubject {
    internal var name: String
    internal var isFolder: Bool
    internal var size: Int64
    internal var modified: Date
    /// The folder the item is in, as the user reads it, without a trailing slash.
    internal var directoryPath: String
    /// The names of the folders above the item, from the top down.
    internal var folders: [String]
    /// Where the item is; only handed to `RenameContext.contentDate`.
    internal var url: URL?

    internal init(
        name: String,
        isFolder: Bool = false,
        size: Int64 = 0,
        modified: Date = Date(timeIntervalSince1970: 0),
        directoryPath: String = "",
        folders: [String]? = nil,
        url: URL? = nil
    ) {
        self.name = name
        self.isFolder = isFolder
        self.size = size
        self.modified = modified
        self.directoryPath = directoryPath
        self.folders =
            folders ?? Array(directoryPath.utf8).split(separator: 0x2F).map { String(decoding: $0, as: UTF8.self) }
        self.url = url
    }

    internal var fullPath: String { directoryPath.hasSuffix("/") ? directoryPath + name : directoryPath + "/" + name }
}

/// The fields of "Define counter" (spec 09 › Define counter).
internal struct CounterDefinition: Codable, Equatable {
    internal var start = 1
    internal var step = 1
    /// The least number of digits; 0 stands for `a`, the width of the number of items.
    internal var digits = 1
}

/// Everything a mask needs besides the item itself.
///
/// A value, so that a preview computed on several threads works on one fixed state.
internal struct RenameContext {
    /// The number of items in the list, for `[c]` and automatic counter widths.
    internal var count = 1
    internal var counter = CounterDefinition()
    /// `[T2]`: when the tool was opened.
    internal var opened = Date()
    /// `[T3]`: when the rename options were last changed.
    internal var changed = Date()
    /// `[X]`: the text on the clipboard, nil when there is none.
    internal var clipboard: String?
    /// `[X]` when `clipboard` is not set: asked only if a mask uses it, on the thread that
    /// works out the names, and answered from the clipboard as it was when the preview began.
    internal var clipboardLoader: (@Sendable () -> String?)?
    internal var environment: [String: String] = [:]
    internal var titleRule = TitleCaseRule.standard
    internal var locale = Locale.current
    internal var timeZone = TimeZone.current
    /// `[T4]`: the date recorded inside a picture.
    ///
    /// Called on the preview threads, several at once.
    internal var contentDate: (@Sendable (RenameSubject) -> Date?)?
}

/// Why a mask gives no name for an item; the preview then shows `<Error!>` (spec 09 › Rename pipeline).
internal enum RenameMaskError: Error, Equatable {
    case invalidPlaceholder(String)
    case emptyClipboard
    case noContentDate
    case contentPluginsUnavailable
    /// A counter that runs beyond what a number can hold.
    case numberTooLarge
}

/// A part of a text by character positions (spec 18 › Range forms): `2-5`, `2,5`, `-8-5`, `02-9`.
internal struct CharacterRange: Equatable {
    internal enum End: Equatable {
        /// One character.
        case single
        case toEnd
        /// Up to this position; negative counts from the end.
        case position(Int)
        case length(Int)
    }

    /// `0` or a space: the result is left-filled to the width the range asks for.
    internal var pad: Character?
    /// 1 is the first character, -1 the last.
    internal var first: Int
    internal var end: End

    internal func apply(to text: String) -> String {
        let characters = Array(text)
        let count = characters.count
        func index(_ position: Int) -> Int { position < 0 ? count + position : position - 1 }
        let start = index(first)
        var last: Int
        var width: Int?
        switch end {
        case .single:
            last = start
            width = 1

        case .toEnd:
            last = count - 1

        case .position(let position):
            // After a start counted from the end, the end is counted from the end as well:
            // `[N-8-5]` is the 8th-last to the 5th-last character.
            let position = first < 0 && position > 0 ? -position : position
            last = index(position)
            if (first < 0) == (position < 0) { width = abs(position - first) + 1 }

        case .length(let length):
            last = start + length - 1
            width = length
        }
        let from = max(start, 0)
        last = min(last, count - 1)
        var result = from <= last ? String(characters[from...last]) : ""
        // No name is longer than 255 characters, so a wider fill is never wanted.
        if let pad, let width = width.map({ min($0, RenameMask.widestFill) }), result.count < width {
            result = String(repeating: pad, count: width - result.count) + result
        }
        return result
    }
}

/// A counter written into the placeholder itself: `[C10+5:3]`, `[C+1/100]`, `[Caa+1]`
/// (spec 18 › Counter).
///
/// It ignores the Define-counter fields.
internal struct InlineCounter: Equatable {
    internal var start = 1
    /// The start of an alphabetic counter (`aa`); its length is the width.
    internal var letters: String?
    internal var step = 1
    /// The counter moves on only every so many items.
    internal var divisor = 1
    /// nil is the automatic width `a`.
    internal var digits: Int? = 1
}

/// A parsed rename mask (spec 18 › Rename and new-folder placeholders).
///
/// Parsing never fails: what cannot be read becomes an `invalid` token, and the mask then gives
/// `<Error!>` for every item.
internal struct RenameMask {
    internal enum Source: Equatable {
        case name, ext, nameWithExt, fullPath, parent, grandparent
        case folderFromRight(Int)
        case folderFromLeft(Int)
        case clipboard(optional: Bool)
        case environment(String, EnvironmentForm)
    }

    internal enum EnvironmentForm: Equatable {
        case whole
        /// `[%VAR%\]`: only the last part of a path.
        case lastPart
        /// `[%VAR%_]`: path separators become this character, colons are dropped.
        case separator(Character)
    }

    internal enum DateField: Character {
        case year4 = "Y"
        case year2 = "y"
        case month = "M"
        case day = "D"
        case hour24 = "h"
        case hour12 = "H"
        case minute = "m"
        case second = "s"
        case millisecond = "v"
        case date = "d"
        case time = "t"
        case amPm = "i"
        case amPmShort = "I"
    }

    internal struct TimeOffset: Equatable {
        internal var value: Int
        internal var unit: Calendar.Component
    }

    /// The units of a time offset: `[T1+5h]` is five hours later.
    private static let offsetUnits: [Character: Calendar.Component] = [
        "s": .second, "m": .minute, "h": .hour, "D": .day, "M": .month, "Y": .year
    ]

    internal enum Token: Equatable {
        case literal(String)
        case text(Source, CharacterRange?)
        case size
        case counter(InlineCounter?)
        /// `[c]`, `[c2]`, `[c3]`.
        case count(Int)
        case date(DateField)
        case timeSource(Int, TimeOffset?)
        case letterCase(LetterCase)
        case precompose
        /// `[I]` toggles, `[I1]` and `[I0]` set the folder-dot switch.
        case folderDot(Bool?)
        case invalid(RenameMaskError)
    }

    internal let tokens: [Token]

    internal init(_ text: String) {
        var tokens: [Token] = []
        var literal = ""
        let characters = Array(text)
        var position = 0
        func flush() {
            if !literal.isEmpty { tokens.append(.literal(literal)) }
            literal = ""
        }
        while position < characters.count {
            let character = characters[position]
            guard character == "[" else {
                literal.append(character)
                position += 1
                continue
            }
            // `[[]` and `[]]` are the brackets themselves.
            if position + 2 < characters.count, characters[position + 2] == "]",
                characters[position + 1] == "[" || characters[position + 1] == "]"
            {
                literal.append(characters[position + 1])
                position += 3
                continue
            }
            flush()
            guard let close = characters[position...].firstIndex(of: "]") else {
                tokens.append(.invalid(.invalidPlaceholder(String(characters[position...]))))
                break
            }
            tokens += Self.commands(Array(characters[(position + 1)..<close]))
            position = close + 1
        }
        flush()
        self.tokens = tokens
    }

    /// The first thing that is wrong with the mask, for a hint next to the field.
    internal var error: RenameMaskError? {
        for case .invalid(let error) in tokens { return error }
        return nil
    }

    // MARK: Parsing

    /// A cursor over the inside of one pair of brackets.
    private struct Scanner {
        let characters: [Character]
        var position = 0

        func peek(_ offset: Int = 0) -> Character? {
            characters.indices.contains(position + offset) ? characters[position + offset] : nil
        }

        mutating func next() -> Character? {
            guard let character = peek() else {
                return nil
            }
            position += 1
            return character
        }

        mutating func accept(_ character: Character) -> Bool {
            guard peek() == character else {
                return false
            }
            position += 1
            return true
        }

        func isDigit(_ offset: Int = 0) -> Bool { peek(offset).map { $0.isASCII && $0.isNumber } ?? false }

        mutating func number() -> Int? {
            var digits = ""
            while isDigit(), digits.count < 9, let digit = next() { digits.append(digit) }
            return Int(digits)
        }

        /// `-5` as well as `5`.
        mutating func signedPosition() -> Int? {
            let start = position
            let negative = accept("-")
            guard let value = number(), value > 0 else {
                position = start
                return nil
            }
            return negative ? -value : value
        }

        func startsPosition(_ offset: Int = 0) -> Bool {
            isDigit(offset) || (peek(offset) == "-" && isDigit(offset + 1))
        }

        var startsRange: Bool {
            startsPosition() || (peek() == " " && startsPosition(1))
        }

        mutating func range() -> CharacterRange? {
            let start = position
            var pad: Character?
            if peek() == "0" || peek() == " ", startsPosition(1) { pad = next() }
            guard let first = signedPosition() else {
                position = start
                return nil
            }
            if accept(",") {
                guard let length = number() else {
                    position = start
                    return nil
                }
                return CharacterRange(pad: pad, first: first, end: .length(length))
            }
            if accept("-") {
                if let last = signedPosition() {
                    return CharacterRange(pad: pad, first: first, end: .position(last))
                }
                return CharacterRange(pad: pad, first: first, end: .toEnd)
            }
            return CharacterRange(pad: pad, first: first, end: .single)
        }
    }

    private static let letterCases: [Character: LetterCase] = [
        "U": .upper, "L": .lower, "F": .words, "f": .titleWords, "n": .unchanged
    ]
    private static let sources: [Character: Source] = [
        "N": .name, "E": .ext, "A": .nameWithExt, "P": .parent, "G": .grandparent
    ]

    /// The commands inside one pair of brackets; several may share it: `[YMD]`, `[hms]`.
    private static func commands(_ content: [Character]) -> [Token] {
        var scanner = Scanner(characters: content)
        var tokens: [Token] = []
        let whole = "[" + String(content) + "]"
        func fail(_ error: RenameMaskError? = nil) -> [Token] { [.invalid(error ?? .invalidPlaceholder(whole))] }
        guard !content.isEmpty else {
            return fail()
        }
        // A range without a letter takes its characters from the full path.
        if scanner.startsRange {
            guard let range = scanner.range() else {
                return fail()
            }
            tokens.append(.text(.fullPath, range))
        }
        while let character = scanner.next() {
            if let source = sources[character] {
                tokens.append(.text(source, scanner.startsRange ? scanner.range() : nil))
            } else if let letterCase = letterCases[character] {
                tokens.append(.letterCase(letterCase))
            } else if character == "i" {
                tokens.append(.date(scanner.accept("1") ? .amPmShort : .amPm))
            } else if character != "I", let field = DateField(rawValue: character) {
                tokens.append(.date(field))
            } else {
                switch character {
                case "X":
                    let optional = scanner.accept("+")
                    tokens.append(.text(.clipboard(optional: optional), scanner.startsRange ? scanner.range() : nil))

                case "B":
                    let fromLeft = scanner.accept("+")
                    guard let level = scanner.number() else {
                        return fail()
                    }
                    var range: CharacterRange?
                    if scanner.accept("_") {
                        guard let parsed = scanner.range() else {
                            return fail()
                        }
                        range = parsed
                    }
                    tokens.append(.text(fromLeft ? .folderFromLeft(level) : .folderFromRight(level), range))

                case "S":
                    tokens.append(.size)

                case "I":
                    tokens.append(.folderDot(scanner.accept("1") ? true : scanner.accept("0") ? false : nil))

                case "C":
                    guard let counter = inlineCounter(&scanner) else {
                        return fail()
                    }
                    tokens.append(.counter(counter.isInline ? counter.definition : nil))

                case "c":
                    let kind = scanner.number() ?? 1
                    guard (1...3).contains(kind) else {
                        return fail()
                    }
                    tokens.append(.count(kind))

                case "T":
                    guard let source = scanner.next().flatMap({ Int(String($0)) }), (1...4).contains(source) else {
                        return fail()
                    }
                    var offset: TimeOffset?
                    if scanner.peek() == "+" || scanner.peek() == "-" {
                        let negative = scanner.next() == "-"
                        guard let value = scanner.number(), let unit = scanner.next().flatMap({ offsetUnits[$0] })
                        else {
                            return fail()
                        }
                        offset = TimeOffset(value: negative ? -value : value, unit: unit)
                    }
                    tokens.append(.timeSource(source, offset))

                case "u":
                    tokens.append(.precompose)

                case "%":
                    var name = ""
                    while let next = scanner.peek(), next != "%" {
                        name.append(next)
                        scanner.position += 1
                    }
                    guard !name.isEmpty, scanner.accept("%") else {
                        return fail()
                    }
                    if scanner.startsRange {
                        tokens.append(.text(.environment(name, .whole), scanner.range()))
                    } else if let form = scanner.next() {
                        tokens.append(
                            .text(.environment(name, form == "\\" || form == "/" ? .lastPart : .separator(form)), nil)
                        )
                    } else {
                        tokens.append(.text(.environment(name, .whole), nil))
                    }

                case "=":
                    return fail(.contentPluginsUnavailable)

                default:
                    return fail()
                }
            }
        }
        return tokens
    }

    /// What follows `C`: `[start][+step][/divisor][:width]`, each part optional.
    private static func inlineCounter(_ scanner: inout Scanner) -> (definition: InlineCounter, isInline: Bool)? {
        var counter = InlineCounter()
        var isInline = false
        if let start = scanner.number() {
            counter.start = start
            isInline = true
        } else if let letter = scanner.peek(), letter.isASCII, letter.isLetter {
            var letters = ""
            while let next = scanner.peek(), next.isASCII, next.isLetter {
                letters.append(next)
                scanner.position += 1
            }
            counter.letters = letters
            isInline = true
        }
        if scanner.peek() == "+" || (scanner.peek() == "-" && scanner.isDigit(1)) {
            var negative = scanner.next() == "-"
            if scanner.accept("-") { negative = true }
            guard let step = scanner.number() else {
                return nil
            }
            counter.step = negative ? -step : step
            isInline = true
        }
        if scanner.accept("/") {
            guard let divisor = scanner.number(), divisor > 0 else {
                return nil
            }
            counter.divisor = divisor
            isInline = true
        }
        if scanner.accept(":") {
            if scanner.accept("a") {
                counter.digits = nil
            } else {
                guard let digits = scanner.number() else {
                    return nil
                }
                counter.digits = digits
            }
            isInline = true
        }
        return (counter, isInline)
    }
}

/// What carries over from the name mask to the extension mask: the folder-dot switch and the
/// time source apply "from this position on" (spec 18 › Name and path parts, Date and time).
internal struct MaskState {
    internal var foldersHaveNoExtension = false
    internal var timeSource = 1
    internal var timeOffset: RenameMask.TimeOffset?
}

/// The date and time formats one preview uses.
///
/// Built once and shared by the preview threads (formatting with a `DateFormatter` is safe from
/// several threads).
///
/// Unchecked `Sendable`: nothing changes after `init`, and the formatters are only used to format.
internal final class RenameFormats: @unchecked Sendable {
    internal let calendar: Calendar
    internal let date: DateFormatter
    internal let time: DateFormatter

    internal init(locale: Locale, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        date = DateFormatter()
        date.locale = locale
        date.timeZone = timeZone
        date.dateStyle = .short
        date.timeStyle = .none
        time = DateFormatter()
        time.locale = locale
        time.timeZone = timeZone
        time.dateStyle = .none
        time.timeStyle = .medium
    }
}

extension RenameMask {
    /// A date and its parts in the calendar of the preview, worked out once per item and time source.
    private struct Moment {
        let date: Date
        let year: Int
        let month: Int
        let day: Int
        let hour: Int
        let minute: Int
        let second: Int
        let nanosecond: Int

        init(_ date: Date, calendar: Calendar) {
            self.date = date
            year = calendar.component(.year, from: date)
            month = calendar.component(.month, from: date)
            day = calendar.component(.day, from: date)
            hour = calendar.component(.hour, from: date)
            minute = calendar.component(.minute, from: date)
            second = calendar.component(.second, from: date)
            nanosecond = calendar.component(.nanosecond, from: date)
        }
    }

    /// The text the mask gives for one item.
    ///
    /// `index` is the item's place in the list, from 0. Safe to call from several threads at once.
    internal func evaluate(
        _ subject: RenameSubject,
        index: Int,
        context: RenameContext,
        formats: RenameFormats,
        state: inout MaskState
    ) throws -> String {
        var pieces: [(text: String, letterCase: LetterCase)] = []
        var letterCase = LetterCase.unchanged
        var precompose = false
        var cachedDate: (source: Int, offset: TimeOffset?, moment: Moment)?

        func moment() throws -> Moment {
            if let cachedDate, cachedDate.source == state.timeSource, cachedDate.offset == state.timeOffset {
                return cachedDate.moment
            }
            var date: Date
            switch state.timeSource {
            case 2:
                date = context.opened

            case 3:
                date = context.changed

            case 4:
                guard let found = context.contentDate?(subject) else { throw RenameMaskError.noContentDate }
                date = found

            default:
                date = subject.modified
            }
            // An offset beyond what the calendar can count leaves the date as it is.
            if let offset = state.timeOffset,
                let shifted = formats.calendar.date(byAdding: offset.unit, value: offset.value, to: date)
            {
                date = shifted
            }
            let found = Moment(date, calendar: formats.calendar)
            cachedDate = (state.timeSource, state.timeOffset, found)
            return found
        }

        func twoDigits(_ value: Int) -> String { String(format: "%02d", value) }

        for token in tokens {
            var text: String?
            switch token {
            case .literal(let literal):
                text = literal

            case .text(let source, let range):
                let value = try Self.value(of: source, subject, context, state)
                text = range?.apply(to: value) ?? value

            case .size:
                text = String(subject.size)

            case .counter(let inline):
                text = try Self.counterText(inline, index: index, context: context)

            case .count(let kind):
                switch kind {
                case 2:
                    text = Self.padded(context.count, digits: Self.width(context.counter.digits, context))

                case 3:
                    text = Self.padded(
                        try Self.number(
                            context.counter.start,
                            plus: context.counter.step,
                            times: max(context.count - 1, 0)
                        ),
                        digits: Self.width(context.counter.digits, context)
                    )

                default:
                    text = String(context.count)
                }

            case .date(let field):
                let moment = try moment()
                let hour = moment.hour
                switch field {
                case .year4:
                    text = String(format: "%04d", moment.year)

                case .year2:
                    text = twoDigits(moment.year % 100)

                case .month:
                    text = twoDigits(moment.month)

                case .day:
                    text = twoDigits(moment.day)

                case .hour24:
                    text = twoDigits(hour)

                case .hour12:
                    text = twoDigits(hour % 12 == 0 ? 12 : hour % 12)

                case .minute:
                    text = twoDigits(moment.minute)

                case .second:
                    text = twoDigits(moment.second)

                case .millisecond:
                    text = String(format: "%03d", min(999, moment.nanosecond / 1_000_000))

                case .amPm:
                    text = hour < 12 ? "am" : "pm"

                case .amPmShort:
                    text = hour < 12 ? "a" : "p"

                case .date:
                    text = Self.nameSafe(formats.date.string(from: moment.date))

                case .time:
                    text = Self.nameSafe(formats.time.string(from: moment.date))
                }

            case .timeSource(let source, let offset):
                state.timeSource = source
                state.timeOffset = offset

            case .letterCase(let newCase):
                letterCase = newCase

            case .precompose:
                precompose = true

            case .folderDot(let setting):
                state.foldersHaveNoExtension = setting ?? !state.foldersHaveNoExtension

            case .invalid(let error):
                throw error
            }
            guard let text, !text.isEmpty else { continue }
            // Neighbours in the same case form one run, so that words are found across them.
            if let last = pieces.indices.last, pieces[last].letterCase == letterCase {
                pieces[last].text += text
            } else {
                pieces.append((text, letterCase))
            }
        }
        let result = pieces.map { $0.letterCase.apply(to: $0.text, rule: context.titleRule) }.joined()
        return precompose ? result.precomposedStringWithCanonicalMapping : result
    }

    /// Name and extension as the masks see them: split at the last dot, also for folders
    /// unless `[I]` is on.
    internal static func parts(of subject: RenameSubject, _ state: MaskState) -> (name: String, ext: String) {
        if subject.isFolder, state.foldersHaveNoExtension {
            return (subject.name, "")
        }
        // As in `FileItem.split`: a leading dot starts no extension, a trailing dot ends none
        // (`Acme Inc.` keeps its dot in the name).
        guard let dot = subject.name.lastIndex(of: "."), dot != subject.name.startIndex,
            subject.name.index(after: dot) != subject.name.endIndex
        else { return (subject.name, "") }
        return (String(subject.name[..<dot]), String(subject.name[subject.name.index(after: dot)...]))
    }

    private static func value(
        of source: Source,
        _ subject: RenameSubject,
        _ context: RenameContext,
        _ state: MaskState
    ) throws -> String {
        let folders = subject.folders
        func fromRight(_ level: Int) -> String {
            folders.indices.contains(folders.count - 1 - level) ? folders[folders.count - 1 - level] : ""
        }
        switch source {
        case .name:
            return parts(of: subject, state).name

        case .ext:
            return parts(of: subject, state).ext

        case .nameWithExt:
            return subject.name

        case .fullPath:
            return subject.fullPath

        case .parent:
            return fromRight(0)

        case .grandparent:
            return fromRight(1)

        case .folderFromRight(let level):
            return fromRight(level)

        // `[B+0]` is the drive letter on Windows; a Mac path has nothing in that place.
        case .folderFromLeft(let level):
            return level >= 1 && folders.indices.contains(level - 1) ? folders[level - 1] : ""

        case .clipboard(let optional):
            guard let text = context.clipboard ?? context.clipboardLoader?(), !text.isEmpty else {
                if optional {
                    return ""
                }
                throw RenameMaskError.emptyClipboard
            }
            let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return String(firstLine.map { "*?:\\|\"<>/".contains($0) ? "_" : $0 })

        case .environment(let name, let form):
            let value = context.environment[name] ?? ""
            switch form {
            case .whole:
                return value

            case .lastPart:
                return value.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""

            case .separator(let separator):
                return String(value.compactMap { $0 == ":" ? nil : ($0 == "/" || $0 == "\\") ? separator : $0 })
            }
        }
    }

    /// A date or time in the regional format, made fit for a name: neither a slash nor a
    /// colon may get into it, and the system's non-breaking spaces become plain ones.
    private static func nameSafe(_ text: String) -> String {
        String(text.map { $0 == "/" ? "-" : $0 == ":" ? "." : ($0 == "\u{202F}" || $0 == "\u{A0}") ? " " : $0 })
    }

    /// The widest fill that is ever written: names do not get longer than this.
    internal static let widestFill = 255

    private static func width(_ digits: Int?, _ context: RenameContext) -> Int {
        guard let digits, digits > 0 else {
            return String(max(context.count, 1)).count
        }
        return min(digits, widestFill)
    }

    internal static func padded(_ value: Int, digits: Int) -> String {
        let text = value == Int.min ? String(value.magnitude) : String(abs(value))
        return (value < 0 ? "-" : "") + String(repeating: "0", count: max(0, min(digits, widestFill) - text.count))
            + text
    }

    /// `start + step * times`; a result beyond the range of numbers is an error of the mask
    /// (`<Error!>`), not a crash.
    internal static func number(_ start: Int, plus step: Int, times: Int) throws -> Int {
        let (distance, overflowed) = step.multipliedReportingOverflow(by: times)
        let (sum, overflowedAgain) = start.addingReportingOverflow(distance)
        guard !overflowed, !overflowedAgain else { throw RenameMaskError.numberTooLarge }
        return sum
    }

    private static func counterText(_ inline: InlineCounter?, index: Int, context: RenameContext) throws -> String {
        guard let inline else {
            return padded(
                try number(context.counter.start, plus: context.counter.step, times: index),
                digits: width(context.counter.digits, context)
            )
        }
        let steps = try number(0, plus: inline.step, times: index / inline.divisor)
        if let letters = inline.letters {
            return try alphabetic(letters, advancedBy: steps)
        }
        return padded(try number(inline.start, plus: steps, times: 1), digits: width(inline.digits, context))
    }

    /// `aa`, `ab`, … `az`, `ba`: the letters are the digits of a number in base 26, as wide
    /// as the start text and in its case.
    ///
    /// Letters that make a number too large for the counter are an error of the mask.
    internal static func alphabetic(_ start: String, advancedBy steps: Int) throws -> String {
        let isUpper = start.first?.isUppercase ?? false
        let base = UInt8(ascii: isUpper ? "A" : "a")
        var value = 0
        for byte in start.lowercased().utf8 {
            let (shifted, overflowed) = value.multipliedReportingOverflow(by: 26)
            let (next, overflowedAgain) = shifted.addingReportingOverflow(Int(byte - UInt8(ascii: "a")))
            guard !overflowed, !overflowedAgain else { throw RenameMaskError.numberTooLarge }
            value = next
        }
        let (advanced, overflowed) = value.addingReportingOverflow(steps)
        guard !overflowed else { throw RenameMaskError.numberTooLarge }
        value = max(0, advanced)
        var letters: [UInt8] = []
        repeat {
            letters.append(base + UInt8(value % 26))
            value /= 26
        } while value > 0
        while letters.count < start.count { letters.append(base) }
        return String(decoding: letters.reversed(), as: UTF8.self)
    }
}
