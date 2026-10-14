import AFMKernel
import Foundation

/// What one panel contributes to the parameters of a command.
struct PanelSnapshot: Equatable {
    /// The panel's directory as the user writes it, with a trailing `/`.
    var path: String
    /// The name under the cursor; nil on `[..]` and in an empty list.
    var cursorName: String?
    /// The marked names, in list order.
    var selection: [String] = []
}

/// Everything the placeholders of a Parameters field can refer to
/// (spec 18 › Button and command parameters).
struct ExpansionContext {
    var left: PanelSnapshot
    var right: PanelSnapshot
    /// The right panel is the active one.
    var sourceIsRight = false
    var environment: [String: String] = [:]
    /// The words typed after the name of a user command; the `%A` codes refer to them.
    var arguments = ""
    /// Where a list file (`%L`, `%F` …) is to be written.
    var listFolder = FileManager.default.temporaryDirectory
    /// The name of the list file without extension; unique per run.
    var listName = UUID().uuidString
    /// The same words when they came out of an expansion already: their values stay values.
    /// Nil stands for `arguments` as the user typed them.
    var argumentPieces: [ExpandedPiece]?

    var source: PanelSnapshot { sourceIsRight ? right : left }
    var target: PanelSnapshot { sourceIsRight ? left : right }
}

/// A list of file names a started program reads (spec 18 › List files). The expansion only says
/// what the file holds; whoever runs the command writes it, off the main thread.
struct ListFile: Equatable {
    let url: URL
    let contents: Data
}

/// One piece of an expanded text. Only `text` is ever read as shell text or searched for
/// placeholders; a `value` is data (a file name, a path, the content of a variable) and reaches
/// a program as it is, whatever characters it holds.
enum ExpandedPiece: Equatable {
    /// What the user wrote.
    case text(String)
    /// Data. The shell gets it in a variable, never as part of the line.
    case value(String)
    /// Data the user asked to have pasted into the line as it is (`%Q`, quoting off).
    case raw(String)
}

struct ExpandedParameters: Equatable {
    var pieces: [ExpandedPiece] = []
    /// The parameters began with `?`: the user is shown the text and may change it.
    var asksFirst = false
    var listFile: ListFile?
    /// An `%A` code used the arguments, so they are not appended a second time.
    var usedArguments = false
    /// A code for the name under the cursor met a panel with no such name (`[..]`, an empty
    /// list). The text then names the folder instead of a file (`rm -rf %P%N`), so the
    /// command must not run.
    var missingName = false
    /// Another reason why the command must not run (a name that cannot stand in a list file).
    var problem: String?

    /// The parameters as one readable line: the values written into it, quoted where they
    /// need it. For commands of the program, for `cd` and for showing; a shell is given
    /// `ShellLine.script` instead.
    var text: String { ShellLine.display(pieces) }
}

/// Quoting for reading and showing a command line. Total Commander quotes names that contain
/// a space; here everything a shell would read as something else is quoted too. Everything
/// works on Unicode scalars: a quote followed by a combining mark is still a quote to a shell.
enum ShellWords {
    /// What may stand in a word without quotes.
    private static let plain = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789%+,-./:@_^")
    private static let quoteSpecial = CharacterSet(charactersIn: "\"\\$`")

    static func needsQuoting(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            if scalar.isASCII { return !plain.contains(scalar) }
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .nonspacingMark,
                .spacingMark, .decimalNumber:
                return false
            default:
                return true
            }
        }
    }

    /// The text as it must be written between double quotes.
    static func escaped(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if quoteSpecial.contains(scalar) { result.append("\\") }
            result.append(scalar)
        }
        return String(result)
    }

    static func quoted(_ text: String) -> String { "\"" + escaped(text) + "\"" }

    /// The text as it must be written between single quotes.
    static func singleQuoteEscaped(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "'" { result.append(contentsOf: "'\\''".unicodeScalars) } else { result.append(scalar) }
        }
        return String(result)
    }

    /// The words of a line; double quotes keep a word with spaces together and stay part of it.
    static func split(_ line: String, at separator: Character = " ") -> [String] {
        let separator = separator.unicodeScalars.first ?? " "
        var words: [String] = []
        var current = String.UnicodeScalarView()
        var inQuotes = false
        var isEscaped = false
        for scalar in line.unicodeScalars {
            if isEscaped {
                isEscaped = false
            } else if scalar == "\\" && inQuotes {
                isEscaped = true
            } else if scalar == "\"" {
                inQuotes.toggle()
            } else if scalar == separator && !inQuotes {
                if !current.isEmpty || separator != " " { words.append(String(current)) }
                current = String.UnicodeScalarView()
                continue
            }
            current.append(scalar)
        }
        if !current.isEmpty || (separator != " " && !words.isEmpty) { words.append(String(current)) }
        return words
    }

    /// The same for an expanded text: a value never ends a word, whatever it holds.
    static func split(_ pieces: [ExpandedPiece]) -> [[ExpandedPiece]] {
        var words: [[ExpandedPiece]] = []
        var current: [ExpandedPiece] = []
        var text = String.UnicodeScalarView()
        var inQuotes = false
        var isEscaped = false
        func flush() {
            if !text.isEmpty { current.append(.text(String(text))) }
            text = String.UnicodeScalarView()
        }
        for piece in pieces {
            guard case .text(let written) = piece else {
                flush()
                current.append(piece)
                isEscaped = false
                continue
            }
            for scalar in written.unicodeScalars {
                if isEscaped {
                    isEscaped = false
                } else if scalar == "\\" && inQuotes {
                    isEscaped = true
                } else if scalar == "\"" {
                    inQuotes.toggle()
                } else if scalar == " " && !inQuotes {
                    flush()
                    if !current.isEmpty { words.append(current) }
                    current = []
                    continue
                }
                text.append(scalar)
            }
        }
        flush()
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// The first word of an expanded line and what follows it, blanks included.
    static func firstWord(of pieces: [ExpandedPiece]) -> (word: [ExpandedPiece], rest: [ExpandedPiece]) {
        var word: [ExpandedPiece] = []
        var inQuotes = false
        var isEscaped = false
        for (index, piece) in pieces.enumerated() {
            guard case .text(let written) = piece else {
                word.append(piece)
                isEscaped = false
                continue
            }
            var text = String.UnicodeScalarView()
            var position = written.unicodeScalars.startIndex
            while position < written.unicodeScalars.endIndex {
                let scalar = written.unicodeScalars[position]
                if isEscaped {
                    isEscaped = false
                } else if scalar == "\\" && inQuotes {
                    isEscaped = true
                } else if scalar == "\"" {
                    inQuotes.toggle()
                } else if scalar == " " && !inQuotes {
                    if text.isEmpty && word.isEmpty {
                        // Blanks in front of the word.
                        position = written.unicodeScalars.index(after: position)
                        continue
                    }
                    if !text.isEmpty { word.append(.text(String(text))) }
                    let tail = String(written.unicodeScalars[position...])
                    return (word, [.text(tail)] + pieces[(index + 1)...])
                }
                text.append(scalar)
                position = written.unicodeScalars.index(after: position)
            }
            if !text.isEmpty { word.append(.text(String(text))) }
        }
        return (word, [])
    }

    /// A word without its double quotes and their escapes: what a command inside the program
    /// is given, since no shell reads it.
    static func unquoted(_ word: String) -> String {
        var result = String.UnicodeScalarView()
        var inQuotes = false
        var isEscaped = false
        for scalar in word.unicodeScalars {
            if isEscaped {
                if !quoteSpecial.contains(scalar) { result.append("\\") }
                result.append(scalar)
                isEscaped = false
            } else if scalar == "\\" && inQuotes {
                isEscaped = true
            } else if scalar == "\"" {
                inQuotes.toggle()
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    /// The same for a word of an expanded text; its values are taken as they are.
    static func unquoted(_ word: [ExpandedPiece]) -> String {
        word.map { piece -> String in
            switch piece {
            case .text(let text): return unquoted(text)
            case .value(let value), .raw(let value): return value
            }
        }.joined()
    }
}

/// Replaces the placeholders of a Parameters field (spec 18 › Button and command parameters).
/// Pure: it reads nothing but its context and writes nothing.
///
/// Adapted to the Mac: there are no 8.3 names, so the lower-case codes insert the same as the
/// upper-case ones; paths end in `/`; the `%L`/`%F`/`%D` lists are UTF-8 without a mark, with
/// one name per line; `%Z` (archives) is accepted and changes nothing.
///
/// What a placeholder stands for is data and stays apart from the text around it
/// (`ExpandedPiece.value`): no name, however it is written, can become part of the command.
struct ParameterExpander {
    let context: ExpansionContext

    func expand(_ parameters: String) -> ExpandedParameters {
        expand([.text(parameters)])
    }

    /// Expands a text that came out of an expansion before (the parameters one user command
    /// hands to another): its text is read for placeholders, its values pass through.
    func expand(_ parameters: [ExpandedPiece]) -> ExpandedParameters {
        var tokens = Run.tokens(of: parameters)
        var asksFirst = false
        if case .scalar("?")? = tokens.first {
            asksFirst = true
            tokens.removeFirst()
        }
        var run = Run(context: context, tokens: tokens)
        run.expand()
        return ExpandedParameters(
            pieces: ParameterExpander.trimmed(run.pieces), asksFirst: asksFirst, listFile: run.listFile,
            usedArguments: run.usedArguments, missingName: run.missingName, problem: run.problem)
    }

    /// Whether a text has a code that needs the marked names of a panel. Making that list
    /// costs a pass over the whole panel, so it is made only for a text that asks for it.
    static func usesSelection(_ pieces: [ExpandedPiece]) -> Bool {
        let codes = Set("SsRrCcLlDFfdUW".unicodeScalars)
        var found = false
        Run.codes(of: Run.tokens(of: pieces)) { if codes.contains($0) { found = true } }
        return found
    }

    /// Joins neighbouring texts and takes the blanks off both ends of the line. Only blanks
    /// the user wrote go: a value keeps every character, a no-break space at its end included.
    static func trimmed(_ pieces: [ExpandedPiece]) -> [ExpandedPiece] {
        var result: [ExpandedPiece] = []
        for piece in pieces {
            if case .text(let text) = piece {
                if text.isEmpty { continue }
                if case .text(let before)? = result.last {
                    result[result.count - 1] = .text(before + text)
                    continue
                }
            }
            result.append(piece)
        }
        func isBlank(_ scalar: Unicode.Scalar) -> Bool { scalar == " " || scalar == "\t" }
        if case .text(let text)? = result.first {
            let kept = String(String.UnicodeScalarView(text.unicodeScalars.drop(while: isBlank)))
            if kept.isEmpty { result.removeFirst() } else { result[0] = .text(kept) }
        }
        if case .text(let text)? = result.last {
            var scalars = text.unicodeScalars
            while let last = scalars.last, isBlank(last) { scalars.removeLast() }
            if scalars.isEmpty { result.removeLast() } else { result[result.count - 1] = .text(String(scalars)) }
        }
        return result
    }

    /// One pass over the text. Placeholders that follow each other directly (`%P%N`) form one
    /// word and one value.
    private struct Run {
        enum Token {
            case scalar(Unicode.Scalar)
            case piece(ExpandedPiece)
        }

        let context: ExpansionContext
        let tokens: [Token]
        var position = 0
        var pieces: [ExpandedPiece] = []
        /// The text written since the last value.
        var literal = String.UnicodeScalarView()
        /// Follows the line as a shell would read it: where a word begins, which quote is open.
        var lexer = ShellContext()
        /// The values of the placeholders read since the last literal character.
        var word: String?
        /// The word so far is a path code alone, which a following `%S` applies to every name.
        var wordIsPath = false
        /// Where the double quote the user opened last began: how many pieces there were, and
        /// how the line stood before it.
        var openQuote: (pieces: Int, lexer: ShellContext)?
        var missingName = false
        var problem: String?
        /// After `%X`: the codes mean the left and right panel instead of source and target.
        var leftRight = false
        var stripsQuotes = false
        var listFile: ListFile?
        var listWasRequested = false
        var usedArguments = false
        let quotesAutomatically: Bool
        let emptyWhenUnselected: Bool
        let dropsListWhenUnselected: Bool
        let includesTargetSelection: Bool

        static func tokens(of pieces: [ExpandedPiece]) -> [Token] {
            var tokens: [Token] = []
            for piece in pieces {
                if case .text(let text) = piece {
                    tokens.append(contentsOf: text.unicodeScalars.map(Token.scalar))
                } else {
                    tokens.append(.piece(piece))
                }
            }
            return tokens
        }

        /// Calls `found` with the letter of every `%<letter>` code; `%%` is the percent sign.
        static func codes(of tokens: [Token], _ found: (Unicode.Scalar) -> Void) {
            var index = 0
            while index < tokens.count {
                defer { index += 1 }
                guard case .scalar("%") = tokens[index], index + 1 < tokens.count,
                    case .scalar(let code) = tokens[index + 1]
                else { continue }
                index += 1
                if code != "%" { found(code) }
            }
        }

        init(context: ExpansionContext, tokens: [Token]) {
            self.context = context
            self.tokens = tokens
            var flags = Set<Unicode.Scalar>()
            Run.codes(of: tokens) { flags.insert($0) }
            quotesAutomatically = !flags.contains("Q")
            emptyWhenUnselected = flags.contains("Y")
            dropsListWhenUnselected = flags.contains("y")
            includesTargetSelection = flags.contains("a")
        }

        private var first: PanelSnapshot { leftRight ? context.left : context.source }
        private var second: PanelSnapshot { leftRight ? context.right : context.target }
        /// The next character of the text; nil at the end and in front of a value.
        private var next: Unicode.Scalar? { scalar(at: position) }

        private func scalar(at index: Int) -> Unicode.Scalar? {
            guard index < tokens.count, case .scalar(let scalar) = tokens[index] else { return nil }
            return scalar
        }

        mutating func expand() {
            while position < tokens.count {
                let token = tokens[position]
                position += 1
                guard case .scalar(let character) = token else {
                    // A value from an earlier expansion: it is passed on, never read.
                    if case .piece(let piece) = token {
                        flushWord()
                        emit(piece)
                    }
                    continue
                }
                guard character == "%", let code = next else {
                    literal(character)
                    continue
                }
                position += 1
                switch code {
                case "%": literal("%")
                case "|": environmentVariable()
                case "P", "p": single(first.path, isPath: true)
                case "T", "t": single(second.path, isPath: true)
                case "N", "n", "v": single(requiring(first.cursorName) ?? "", isName: true)
                case "V": single(requiring(first.cursorName).map { first.path + $0 } ?? "")
                case "M", "m": single(requiring(second.cursorName) ?? "", isName: true)
                case "O", "o": single(FileItem.split(requiring(first.cursorName) ?? "").base, isName: true)
                case "E", "e": single(FileItem.split(requiring(first.cursorName) ?? "").ext)
                case "S", "s": names(of: first)
                case "R", "r": names(of: second)
                case "B", "b": directoryName()
                case "C", "c": comparedFile(code)
                case "A": arguments()
                case "L", "l", "D": list(withPath: true, encoding: .plain)
                case "F", "f", "d": list(withPath: false, encoding: .plain)
                case "U", "W":
                    guard let kind = next, kind == "L" || kind == "F" else {
                        literal("%")
                        literal(code)
                        continue
                    }
                    position += 1
                    list(withPath: kind == "L", encoding: code == "U" ? .utf8WithMark : .utf16WithMark)
                case "X": leftRight = true
                case "x": leftRight = false
                case "q": stripsQuotes.toggle()
                case "Y", "y", "Z", "Q", "a": break
                default:
                    literal("%")
                    literal(code)
                }
            }
            flushWord()
            flushLiteral()
        }

        // MARK: Output

        private var isInsideDoubleQuotes: Bool { lexer.place == .doubleQuoted }

        /// A character the user wrote.
        private mutating func literal(_ character: Unicode.Scalar) {
            flushWord()
            let wasInside = isInsideDoubleQuotes
            var opened: (pieces: Int, lexer: ShellContext)?
            if character == "\"", !wasInside {
                flushLiteral()
                opened = (pieces.count, lexer)
            }
            write(character)
            guard character == "\"" else { return }
            if !wasInside, isInsideDoubleQuotes {
                openQuote = opened
            } else if wasInside, !isInsideDoubleQuotes {
                openQuote = nil
            }
        }

        private mutating func write(_ character: Unicode.Scalar) {
            literal.append(character)
            lexer.feed(character)
        }

        private mutating func write(_ text: String) {
            for scalar in text.unicodeScalars { write(scalar) }
        }

        private mutating func flushLiteral() {
            guard !literal.isEmpty else { return }
            pieces.append(.text(String(literal)))
            literal = String.UnicodeScalarView()
        }

        /// Data goes out as a value; with `%Q` it is pasted into the line as it is.
        private mutating func emit(value: String) {
            flushLiteral()
            if quotesAutomatically {
                pieces.append(.value(value))
                lexer.feedValue()
            } else {
                pieces.append(.raw(value))
                lexer.feed(value)
            }
        }

        private mutating func emit(_ piece: ExpandedPiece) {
            switch piece {
            case .text(let text): write(text)
            case .value(let value):
                flushLiteral()
                pieces.append(.value(value))
                lexer.feedValue()
            case .raw(let value):
                flushLiteral()
                pieces.append(.raw(value))
                lexer.feed(value)
            }
        }

        /// The name under the cursor, noting when there is none.
        private mutating func requiring(_ name: String?) -> String? {
            if name == nil { missingName = true }
            return name
        }

        /// A name that begins with `-` would be read as an option: `./` in front says it is a file.
        private func protected(_ name: String) -> String {
            name.unicodeScalars.first == "-" && quotesAutomatically ? "./" + name : name
        }

        private mutating func single(_ value: String, isPath: Bool = false, isName: Bool = false) {
            var value = substring()(value)
            // Only at the start of a word of the line: after a blank inside the user's quotes
            // the name is no argument of its own.
            if isName, word == nil, lexer.isAtWordStart { value = protected(value) }
            wordIsPath = word == nil && isPath
            word = (word ?? "") + value
        }

        private mutating func flushWord() {
            guard let value = word else { return }
            word = nil
            wordIsPath = false
            emit(value: value)
        }

        // MARK: Numbers, ranges and substrings

        /// A number of any length: one too large to hold counts as the largest there is.
        private mutating func number() -> Int? {
            var value: Int?
            while let character = next, character.value >= 48, character.value <= 57 {
                let digit = Int(character.value - 48)
                let (product, overflowed) = (value ?? 0).multipliedReportingOverflow(by: 10)
                let (sum, carried) = product.addingReportingOverflow(digit)
                value = overflowed || carried ? Int.max : sum
                position += 1
            }
            return value
        }

        /// Positions `from`…`to` (1-based) of a list, counted from the start or from the end.
        private static func slice<Element>(_ items: [Element], fromEnd: Bool, _ start: Int, _ end: Int?, open: Bool)
            -> [Element]
        {
            // The numbers are the user's and may be as large as an `Int`: nothing here may overflow.
            func fromTheEnd(_ index: Int) -> Int { index > items.count ? 0 : items.count - index + 1 }
            let from = fromEnd ? fromTheEnd(start) : start
            let to = open ? items.count : end.map { fromEnd ? fromTheEnd($0) : $0 } ?? from
            guard from >= 1, from <= min(to, items.count) else { return [] }
            return Array(items[(from - 1)..<min(to, items.count)])
        }

        /// `-<m>` or an open `-` after a position; restores the position when there is neither.
        private mutating func rangeEnd(openWith openers: Set<Unicode.Scalar>) -> (end: Int?, open: Bool) {
            guard let character = next, openers.contains(character) else { return (nil, false) }
            position += 1
            if character == "-", let end = number() { return (end, false) }
            return (nil, true)
        }

        /// The forms after `%S`: `<n>`, `+<n>`, `+<n>-<m>`, `+<n>-`, `-<n>`, `-<n>-<m>`, `-<n>-`.
        private mutating func selectionRange() -> ([String]) -> [String] {
            let start = position
            guard let sign = next, sign == "+" || sign == "-" else {
                guard let count = number() else { return { $0 } }
                return { Array($0.prefix(count)) }
            }
            position += 1
            guard let index = number() else {
                position = start
                return { $0 }
            }
            let (end, open) = rangeEnd(openWith: ["-"])
            return { Run.slice($0, fromEnd: sign == "-", index, end, open: open) }
        }

        /// The cmd.exe-style suffix `:~start,length` (spec 18 › Substrings).
        private mutating func substring() -> (String) -> String {
            guard scalar(at: position) == ":", scalar(at: position + 1) == "~" else { return { $0 } }
            let begin = position
            position += 2
            let startIsNegative = next == "-"
            if startIsNegative { position += 1 }
            guard let start = number() else {
                position = begin
                return { $0 }
            }
            var length: Int?
            var lengthIsNegative = false
            if next == "," {
                let comma = position
                position += 1
                lengthIsNegative = next == "-"
                if lengthIsNegative { position += 1 }
                length = number()
                if length == nil { position = comma }
            }
            if length != nil, next == "~" { position += 1 }
            return { text in
                if startIsNegative && start == 0 {
                    // `-0` cuts the name without its extension, or the extension alone.
                    let parts = FileItem.split(text)
                    guard let length else { return parts.base }
                    return String((lengthIsNegative ? parts.ext : parts.base).prefix(length))
                }
                let all = Array(text)
                let from = startIsNegative ? max(0, all.count - min(start, all.count)) : min(start, all.count)
                var to = all.count
                if let length {
                    // `from + length` with a length as large as an `Int` would overflow.
                    to =
                        lengthIsNegative
                        ? all.count - min(length, all.count) : (length >= all.count - from ? all.count : from + length)
                }
                return from < to ? String(all[from..<to]) : ""
            }
        }

        // MARK: Codes

        private mutating func environmentVariable() {
            var name = String.UnicodeScalarView()
            while let character = next {
                position += 1
                if character == "|" { break }
                name.append(character)
            }
            flushWord()
            emit(value: stripped(context.environment[String(name)] ?? ""))
        }

        /// The names a multi-file code stands for; nil when the list parameter is to be dropped
        /// (spec 18 › Empty-selection and archive modifiers).
        private func chosen(of panel: PanelSnapshot, forList: Bool) -> [String]? {
            if !panel.selection.isEmpty { return panel.selection }
            let cursor = panel.cursorName.map { [$0] }
            switch (emptyWhenUnselected, dropsListWhenUnselected) {
            case (true, true): return cursor ?? (forList ? nil : [])
            case (true, false): return []
            case (false, true): return forList ? nil : cursor ?? []
            case (false, false): return cursor ?? []
            }
        }

        /// `%S`, `%R`: every name is its own word. A path code directly in front goes before
        /// each name; inside the user's quotes each name gets its own pair, with the text
        /// around the code as affixes (`"before%Sbeforeext%Eafterext"`).
        private mutating func names(of panel: PanelSnapshot) {
            let range = selectionRange()
            let cut = substring()
            var prefix = ""
            if wordIsPath, let path = word {
                prefix = path
                word = nil
                wordIsPath = false
            } else {
                flushWord()
            }
            let names = range(chosen(of: panel, forList: false) ?? []).map(cut)
            guard isInsideDoubleQuotes, let quote = openQuote else {
                for (index, name) in names.enumerated() {
                    if index > 0 { write(" ") }
                    emit(value: prefix.isEmpty && lexer.isAtWordStart ? protected(name) : prefix + name)
                }
                return
            }
            // The quote and what the user wrote after it come out of the line again and are
            // written once for every name.
            flushLiteral()
            var before = Array(pieces[quote.pieces...])
            pieces.removeSubrange(quote.pieces...)
            if case .text(let text)? = before.first { before[0] = .text(String(text.unicodeScalars.dropFirst())) }
            before = ParameterExpander.joined(before)
            lexer = quote.lexer
            openQuote = nil
            let startsWord = lexer.isAtWordStart
            var tail: [ExpandedPiece] = []
            var written = String.UnicodeScalarView()
            while position < tokens.count {
                let token = tokens[position]
                position += 1
                guard case .scalar(let character) = token else {
                    if case .piece(let piece) = token {
                        tail.append(.text(String(written)))
                        tail.append(piece)
                        written = String.UnicodeScalarView()
                    }
                    continue
                }
                if character == "\"" { break }
                written.append(character)
                // An escaped quote does not end the user's quotes.
                if character == "\\", let escaped = next {
                    written.append(escaped)
                    position += 1
                }
            }
            tail.append(.text(String(written)))
            let affixes = ParameterExpander.split(ParameterExpander.joined(tail), at: "%E")
            for (index, name) in names.enumerated() {
                if index > 0 { write(" ") }
                write("\"")
                before.forEach { emit($0) }
                if let affixes {
                    let parts = FileItem.split(name)
                    let base =
                        prefix.isEmpty && before.isEmpty && startsWord ? protected(parts.base) : prefix + parts.base
                    emit(value: base)
                    affixes.before.forEach { emit($0) }
                    if !parts.ext.isEmpty { emit(value: "." + parts.ext) }
                    affixes.after.forEach { emit($0) }
                } else {
                    emit(value: prefix.isEmpty && before.isEmpty && startsWord ? protected(name) : prefix + name)
                    tail.forEach { emit($0) }
                }
                write("\"")
            }
        }

        /// `%B` and its forms: one directory name of the source or target path.
        private mutating func directoryName() {
            var panel = first
            var fromStart = false
            if next == "T" {
                panel = second
                position += 1
            } else if next == "+" {
                fromStart = true
                position += 1
            } else if next == "-" {
                // Without the branch-view part, which panels here do not have.
                position += 1
            }
            var index: Int?
            if let digit = next, digit.value >= 48, digit.value <= 57 {
                index = Int(digit.value - 48)
                position += 1
            }
            // (Cut at the `/` bytes: a name may begin with a combining mark, which a cut by characters would glue to the `/`.)
            let parts = Array(panel.path.utf8).split(separator: 0x2F).map { String(decoding: $0, as: UTF8.self) }
            if fromStart {
                // The Mac has no drive letters: `%B+` is the root, `%B+0` is empty.
                guard let index else { return single("/") }
                single(index >= 1 && index <= parts.count ? parts[index - 1] : "")
            } else {
                let back = index ?? 0
                single(back < parts.count ? parts[parts.count - 1 - back] : "")
            }
        }

        /// `%C1` … `%C9`: the files Compare by Content would take, with their paths.
        private mutating func comparedFile(_ code: Unicode.Scalar) {
            guard let digit = next, digit.value >= 49, digit.value <= 57 else {
                literal("%")
                literal(code)
                return
            }
            let number = Int(digit.value - 48)
            position += 1
            let source = first
            let target = second
            let selected = source.selection
            guard number <= 2 else { return single(selected.count >= number ? source.path + selected[number - 1] : "") }
            let firstName = selected.first ?? source.cursorName
            var one = firstName.map { source.path + $0 } ?? ""
            var two =
                selected.count >= 2
                ? source.path + selected[1]
                : (target.selection.first ?? firstName).map { target.path + $0 } ?? ""
            if context.sourceIsRight && selected.count < 2 { swap(&one, &two) }
            single(number == 1 ? one : two)
        }

        /// `%A` and its forms: the words typed after the command's name (spec 18 › Alias-only codes).
        private mutating func arguments() {
            usedArguments = true
            flushWord()
            let typed = context.argumentPieces ?? [.text(context.arguments)]
            let start = position
            let fromEnd = next == "-"
            if fromEnd { position += 1 }
            guard let index = number() else {
                position = start
                typed.forEach { emit(stripped($0)) }
                return
            }
            let (end, open) = rangeEnd(openWith: ["-", "+"])
            let words = Run.slice(ShellWords.split(typed), fromEnd: fromEnd, index, end, open: open)
            for (index, word) in words.enumerated() {
                if index > 0 { write(" ") }
                word.forEach { emit(stripped($0)) }
            }
        }

        private func stripped(_ text: String) -> String {
            stripsQuotes ? String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != "\"" })) : text
        }

        /// `%q` takes the double quotes out of what the user typed; a value has none of its own.
        private func stripped(_ piece: ExpandedPiece) -> ExpandedPiece {
            if case .text(let text) = piece { return .text(stripped(text)) }
            return piece
        }

        private enum ListEncoding {
            case plain, utf8WithMark, utf16WithMark
        }

        /// A list code puts the name of the list file into the line. Only the first list of a
        /// command counts.
        private mutating func list(withPath: Bool, encoding: ListEncoding) {
            guard !listWasRequested else { return }
            listWasRequested = true
            let panel = first
            guard let names = chosen(of: panel, forList: true) else { return }
            // Without a path a name that begins with `-` would be an option to whoever reads the list.
            func line(_ name: String, of panel: PanelSnapshot) -> String {
                withPath ? panel.path + name : protected(name)
            }
            var lines = names.map { line($0, of: panel) }
            if includesTargetSelection { lines += second.selection.map { line($0, of: second) } }
            // The list has one name per line, so a name with a line break in it would be read
            // as two other files. Such a list is not written.
            // Every character that a program may take for the end of a line (Python's `splitlines`
            // knows these) counts as one.
            func endsALine(_ scalar: Unicode.Scalar) -> Bool {
                switch scalar.value {
                case 0x0A...0x0D, 0x1C...0x1E, 0x85, 0x2028, 0x2029: return true
                default: return false
                }
            }
            if let broken = lines.first(where: { $0.unicodeScalars.contains(where: endsALine) }) {
                problem =
                    "The name “\(DisplayText.oneLine(broken))” contains a line break and cannot be passed in a list file."
            }
            let text = lines.map { $0 + "\n" }.joined()
            var contents = Data()
            switch encoding {
            case .plain: contents = Data(text.utf8)
            case .utf8WithMark: contents = Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
            case .utf16WithMark: contents = Data([0xFF, 0xFE]) + (text.data(using: .utf16LittleEndian) ?? Data())
            }
            let url = context.listFolder.appendingPathComponent("list-\(context.listName).txt")
            listFile = ListFile(url: url, contents: contents)
            single(url.path)
        }
    }

    /// Neighbouring texts as one, empty ones left out.
    fileprivate static func joined(_ pieces: [ExpandedPiece]) -> [ExpandedPiece] {
        var result: [ExpandedPiece] = []
        for piece in pieces {
            if case .text(let text) = piece {
                if text.isEmpty { continue }
                if case .text(let before)? = result.last {
                    result[result.count - 1] = .text(before + text)
                    continue
                }
            }
            result.append(piece)
        }
        return result
    }

    /// What stands before and after the first `marker` in the text of the pieces; nil without one.
    fileprivate static func split(_ pieces: [ExpandedPiece], at marker: String) -> (
        before: [ExpandedPiece], after: [ExpandedPiece]
    )? {
        for (index, piece) in pieces.enumerated() {
            guard case .text(let text) = piece, let found = text.range(of: marker, options: .literal) else { continue }
            let before = Array(pieces[..<index]) + [.text(String(text[..<found.lowerBound]))]
            let after = [.text(String(text[found.upperBound...]))] + Array(pieces[(index + 1)...])
            return (joined(before), joined(after))
        }
        return nil
    }
}

/// Text that came from outside (a file name, a path, a stored value) made fit for a message, a
/// log line or a dialog: line breaks and control characters cannot draw a second line or hide
/// what follows, and a very long text is cut.
enum DisplayText {
    static func oneLine(_ text: String, limit: Int = 200) -> String {
        var result = String.UnicodeScalarView()
        var count = 0
        for scalar in text.unicodeScalars {
            if count >= limit {
                result.append("…")
                break
            }
            count += 1
            switch scalar {
            case "\n": result.append(contentsOf: "\\n".unicodeScalars)
            case "\r": result.append(contentsOf: "\\r".unicodeScalars)
            case "\t": result.append(contentsOf: "\\t".unicodeScalars)
            default:
                switch scalar.properties.generalCategory {
                // The joiners of emoji and of some scripts are format characters too, and harmless.
                case .format where scalar.value == 0x200C || scalar.value == 0x200D:
                    result.append(scalar)
                case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate:
                    result.append(contentsOf: "\\u{\(String(scalar.value, radix: 16, uppercase: true))}".unicodeScalars)
                default:
                    result.append(scalar)
                }
            }
        }
        return String(result)
    }
}
