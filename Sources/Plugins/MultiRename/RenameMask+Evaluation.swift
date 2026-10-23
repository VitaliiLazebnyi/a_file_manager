import Foundation

/// Working out the text a mask gives for one item.
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

    /// The moment last worked out, and for which time source.
    private struct CachedMoment {
        let source: Int
        let offset: TimeOffset?
        let moment: Moment
    }

    /// A run of the result in one letter case: neighbours in the same case form one run, so that
    /// words are found across them.
    private struct Run {
        var text: String
        var letterCase: LetterCase
    }

    /// One evaluation of the mask for one item.
    private struct Evaluation {
        let subject: RenameSubject
        let index: Int
        let context: RenameContext
        let formats: RenameFormats
        var state: MaskState
        var runs: [Run] = []
        var letterCase = LetterCase.unchanged
        var precompose = false
        var cached: CachedMoment?

        /// The result so far, each run in its case.
        var result: String {
            let text = runs.map { $0.letterCase.apply(to: $0.text, rule: context.titleRule) }.joined()
            return precompose ? text.precomposedStringWithCanonicalMapping : text
        }

        /// Takes in one token: its text, or what it switches.
        mutating func take(_ token: Token) throws {
            guard let text = try text(of: token) else {
                try apply(token)
                return
            }
            guard !text.isEmpty else {
                return
            }
            if let last = runs.indices.last, runs[last].letterCase == letterCase {
                runs[last].text += text
            } else {
                runs.append(Run(text: text, letterCase: letterCase))
            }
        }

        /// The text of a token that gives text; nil for one that switches something.
        mutating func text(of token: Token) throws -> String? {
            switch token {
            case .literal(let literal):
                return literal

            case .text(let source, let range):
                let value = try RenameMask.value(of: source, subject, context, state)
                return range?.apply(to: value) ?? value

            case .size:
                return String(subject.size)

            case .counter(let inline):
                return try RenameMask.counterText(inline, index: index, context: context)

            case .count(let kind):
                return try RenameMask.countText(kind, context: context)

            case .date(let field):
                return RenameMask.text(of: field, at: try moment(), formats: formats)

            // The tokens that switch something (`apply`).

            default:
                return nil
            }
        }

        /// What a token that gives no text switches: the time source, the letter case, the folder-dot
        /// switch, precomposing; an invalid one throws its error.
        mutating func apply(_ token: Token) throws {
            if case .timeSource(let source, let offset) = token {
                (state.timeSource, state.timeOffset) = (source, offset)
            } else if case .letterCase(let newCase) = token {
                letterCase = newCase
            } else if case .folderDot(let setting) = token {
                switch setting {
                case .clear:
                    state.foldersHaveNoExtension = false

                case .set:
                    state.foldersHaveNoExtension = true

                case .toggle:
                    state.foldersHaveNoExtension.toggle()
                }
            } else if case .invalid(let error) = token {
                throw error
            } else {
                // The one left is `[u]`.
                precompose = true
            }
        }

        /// The date of the time source now in force, worked out once for as long as it stays.
        mutating func moment() throws -> Moment {
            if let cached, cached.source == state.timeSource, cached.offset == state.timeOffset {
                return cached.moment
            }
            var date: Date
            switch state.timeSource {
            case 2:
                date = context.opened

            case 3:
                date = context.changed

            case 4:
                guard let found = context.contentDate?(subject) else {
                    throw RenameMaskError.noContentDate
                }
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
            cached = CachedMoment(source: state.timeSource, offset: state.timeOffset, moment: found)
            return found
        }
    }

    /// The widest fill that is ever written: names do not get longer than this.
    internal static let widestFill = 255

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
        else {
            return (subject.name, "")
        }
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
            return try clipboardText(optional: optional, context)

        case .environment(let name, let form):
            return environmentText(name, form, context)
        }
    }

    /// `[X]`: the first line of the clipboard, made fit for a name; an empty clipboard gives
    /// nothing with `optional`, else no name.
    private static func clipboardText(optional: Bool, _ context: RenameContext) throws -> String {
        guard let text = context.clipboard ?? context.clipboardLoader?(), !text.isEmpty else {
            if optional {
                return ""
            }
            throw RenameMaskError.emptyClipboard
        }
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return String(firstLine.map { "*?:\\|\"<>/".contains($0) ? "_" : $0 })
    }

    /// `[%NAME%]`: the variable in its form.
    private static func environmentText(_ name: String, _ form: EnvironmentForm, _ context: RenameContext) -> String {
        let value = context.environment[name] ?? ""
        switch form {
        case .whole:
            return value

        case .lastPart:
            return value.split { $0 == "/" || $0 == "\\" }.last.map(String.init) ?? ""

        case .separator(let separator):
            return String(value.compactMap { $0 == ":" ? nil : ($0 == "/" || $0 == "\\") ? separator : $0 })
        }
    }

    /// A date or time in the regional format, made fit for a name: neither a slash nor a
    /// colon may get into it, and the system's non-breaking spaces become plain ones.
    private static func nameSafe(_ text: String) -> String {
        String(text.map { $0 == "/" ? "-" : $0 == ":" ? "." : ($0 == "\u{202F}" || $0 == "\u{A0}") ? " " : $0 })
    }

    private static func twoDigits(_ value: Int) -> String { String(format: "%02d", value) }

    private static func width(_ digits: Int?, _ context: RenameContext) -> Int {
        guard let digits, digits > 0 else {
            return String(max(context.count, 1)).count
        }
        return min(digits, widestFill)
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

    /// `[c]` the number of items, `[c2]` the same as wide as the counter, `[c3]` the counter of the last item.
    private static func countText(_ kind: Int, context: RenameContext) throws -> String {
        switch kind {
        case 2:
            return padded(context.count, digits: width(context.counter.digits, context))

        case 3:
            return padded(
                try number(context.counter.start, plus: context.counter.step, times: max(context.count - 1, 0)),
                digits: width(context.counter.digits, context)
            )

        default:
            return String(context.count)
        }
    }

    /// The text of a date field at `moment`.
    private static func text(of field: DateField, at moment: Moment, formats: RenameFormats) -> String {
        switch field {
        case .year4:
            return String(format: "%04d", moment.year)

        case .year2:
            return twoDigits(moment.year % 100)

        case .month:
            return twoDigits(moment.month)

        case .day:
            return twoDigits(moment.day)

        case .hour24, .hour12:
            let hour12 = moment.hour.isMultiple(of: 12) ? 12 : moment.hour % 12
            return twoDigits(field == .hour24 ? moment.hour : hour12)

        case .minute, .second:
            return twoDigits(field == .minute ? moment.minute : moment.second)

        case .millisecond:
            return String(format: "%03d", min(999, moment.nanosecond / 1_000_000))

        case .amPm, .amPmShort:
            let morning = moment.hour < 12
            return field == .amPm ? (morning ? "am" : "pm") : (morning ? "a" : "p")

        case .date, .time:
            return nameSafe((field == .date ? formats.date : formats.time).string(from: moment.date))
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
        var evaluation = Evaluation(subject: subject, index: index, context: context, formats: formats, state: state)
        defer { state = evaluation.state }
        for token in tokens {
            try evaluation.take(token)
        }
        return evaluation.result
    }
}
