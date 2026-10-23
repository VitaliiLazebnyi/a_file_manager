import Foundation

/// Reading the placeholders of a mask, one pair of brackets at a time.
extension RenameMask {
    /// The units of a time offset: `[T1+5h]` is five hours later.
    private static let offsetUnits: [Character: Calendar.Component] = [
        "s": .second, "m": .minute, "h": .hour, "D": .day, "M": .month, "Y": .year
    ]

    private static let letterCases: [Character: LetterCase] = [
        "U": .upper, "L": .lower, "F": .words, "f": .titleWords, "n": .unchanged
    ]

    private static let sources: [Character: Source] = [
        "N": .name, "E": .ext, "A": .nameWithExt, "P": .parent, "G": .grandparent
    ]

    /// The placeholders of the other letters, each reading what follows its letter; nil when that
    /// cannot be read.
    private static let parsers: [Character: @Sendable (inout RenameMaskScanner) -> Token?] = [
        "X": Self.clipboard, "B": Self.folder, "S": { _ in .size }, "I": Self.folderDot, "C": Self.counter,
        "c": Self.count, "T": Self.timeSource, "u": { _ in .precompose }, "%": Self.environment,
        "=": { _ in .invalid(.contentPluginsUnavailable) }
    ]

    /// The commands inside one pair of brackets; several may share it: `[YMD]`, `[hms]`.
    internal static func commands(_ content: [Character]) -> [Token] {
        var scanner = RenameMaskScanner(characters: content)
        let invalid = [Token.invalid(.invalidPlaceholder("[" + String(content) + "]"))]
        guard !content.isEmpty else {
            return invalid
        }
        var found: [Token] = []
        // A range without a letter takes its characters from the full path.
        if scanner.startsRange {
            guard let range = scanner.range() else {
                return invalid
            }
            found.append(.text(.fullPath, range))
        }
        while let character = scanner.next() {
            guard let token = token(for: character, &scanner) else {
                return invalid
            }
            if case .invalid = token {
                return [token]
            }
            found.append(token)
        }
        return found
    }

    /// The command of `character`, read on from the scanner; nil when it cannot be read.
    private static func token(for character: Character, _ scanner: inout RenameMaskScanner) -> Token? {
        if let source = sources[character] {
            return .text(source, scanner.startsRange ? scanner.range() : nil)
        }
        if let letterCase = letterCases[character] {
            return .letterCase(letterCase)
        }
        if character == "i" {
            return .date(scanner.accept("1") ? .amPmShort : .amPm)
        }
        if character != "I", let field = DateField(rawValue: character) {
            return .date(field)
        }
        return parsers[character]?(&scanner)
    }

    /// `[X]`, `[X+]`, with a range.
    private static func clipboard(_ scanner: inout RenameMaskScanner) -> Token? {
        let optional = scanner.accept("+")
        return .text(.clipboard(optional: optional), scanner.startsRange ? scanner.range() : nil)
    }

    /// `[Bn]`, `[B+n]`, with a range after `_`.
    private static func folder(_ scanner: inout RenameMaskScanner) -> Token? {
        let fromLeft = scanner.accept("+")
        guard let level = scanner.number() else {
            return nil
        }
        var range: CharacterRange?
        if scanner.accept("_") {
            guard let parsed = scanner.range() else {
                return nil
            }
            range = parsed
        }
        return .text(fromLeft ? .folderFromLeft(level) : .folderFromRight(level), range)
    }

    /// `[I]`, `[I1]`, `[I0]`.
    private static func folderDot(_ scanner: inout RenameMaskScanner) -> Token? {
        .folderDot(scanner.accept("1") ? .set : scanner.accept("0") ? .clear : .toggle)
    }

    /// `[C]` and the counters written into the placeholder.
    private static func counter(_ scanner: inout RenameMaskScanner) -> Token? {
        guard let counter = inlineCounter(&scanner) else {
            return nil
        }
        return .counter(counter.isInline ? counter.definition : nil)
    }

    /// `[c]`, `[c2]`, `[c3]`.
    private static func count(_ scanner: inout RenameMaskScanner) -> Token? {
        let kind = scanner.number() ?? 1
        guard (1...3).contains(kind) else {
            return nil
        }
        return .count(kind)
    }

    /// `[T1]` to `[T4]`, with an offset such as `+5h`.
    private static func timeSource(_ scanner: inout RenameMaskScanner) -> Token? {
        guard let source = scanner.next().flatMap({ Int(String($0)) }), (1...4).contains(source) else {
            return nil
        }
        var offset: TimeOffset?
        if scanner.peek(0) == "+" || scanner.peek(0) == "-" {
            let negative = scanner.next() == "-"
            guard let value = scanner.number(), let unit = scanner.next().flatMap({ offsetUnits[$0] }) else {
                return nil
            }
            offset = TimeOffset(value: negative ? -value : value, unit: unit)
        }
        return .timeSource(source, offset)
    }

    /// `[%NAME%]`, with a range or a form after the second `%`.
    private static func environment(_ scanner: inout RenameMaskScanner) -> Token? {
        var name = ""
        while let next = scanner.peek(0), next != "%" {
            name.append(next)
            scanner.position += 1
        }
        guard !name.isEmpty, scanner.accept("%") else {
            return nil
        }
        if scanner.startsRange {
            return .text(.environment(name, .whole), scanner.range())
        }
        if let form = scanner.next() {
            return .text(.environment(name, form == "\\" || form == "/" ? .lastPart : .separator(form)), nil)
        }
        return .text(.environment(name, .whole), nil)
    }

    /// What follows `C`: `[start][+step][/divisor][:width]`, each part optional; nil when a part
    /// cannot be read.
    private static func inlineCounter(_ scanner: inout RenameMaskScanner) -> (
        definition: InlineCounter, isInline: Bool
    )? {
        var counter = InlineCounter()
        var isInline = readStart(of: &counter, &scanner)
        if scanner.peek(0) == "+" || (scanner.peek(0) == "-" && scanner.isDigit(1)) {
            guard readStep(of: &counter, &scanner) else {
                return nil
            }
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

    /// The start of an inline counter, a number or letters; whether there was one.
    private static func readStart(of counter: inout InlineCounter, _ scanner: inout RenameMaskScanner) -> Bool {
        if let start = scanner.number() {
            counter.start = start
            return true
        }
        guard let letter = scanner.peek(0), letter.isASCII, letter.isLetter else {
            return false
        }
        var letters = ""
        while let next = scanner.peek(0), next.isASCII, next.isLetter {
            letters.append(next)
            scanner.position += 1
        }
        counter.letters = letters
        return true
    }

    /// The step of an inline counter (`+5`, `-5`, `+-5`), at the sign; false when it cannot be read.
    private static func readStep(of counter: inout InlineCounter, _ scanner: inout RenameMaskScanner) -> Bool {
        var negative = scanner.next() == "-"
        if scanner.accept("-") {
            negative = true
        }
        guard let step = scanner.number() else {
            return false
        }
        counter.step = negative ? -step : step
        return true
    }
}
