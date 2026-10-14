import Foundation

/// Follows a command line the way a shell reads it, far enough to say where a value may stand
/// and how a reference to it must be written there. It reads only what the user wrote: values
/// are announced with `feedValue()` and never looked at.
///
/// It knows single and double quotes, `$'…'`, backslashes, backticks, `$(…)`, `$((…))`,
/// `${…}`, comments and the `<<` of a here-document. Where it cannot be sure of the place
/// (inside `$'…'`, backticks, a comment, after `<<`, after a construct it does not follow), it
/// refuses: the command is then not run, which is always safe. It also refuses the places
/// where a shell works a value out as arithmetic, because there a value is read as an
/// expression again and can run a command: `$((…))`, `((…))`, `$[…]`, the subscript of
/// `$name[…]`, and a test (`[[ … ]]`, `[ … ]`, `test`) that compares numbers. Works on Unicode
/// scalars, as a shell works on bytes: every character that means something to a shell is ASCII.
struct ShellContext {
    /// Where a value stands.
    enum Place: Equatable {
        /// In a word of the line, outside every quote.
        case word
        case doubleQuoted
        case singleQuoted
    }

    /// Why no value can stand at a place.
    enum Refusal: Error, Equatable {
        case ansiQuote, backtick, hereDocument, comment, backslash, dollar, arithmetic, parameterExpansion,
            caseInSubstitution

        var explanation: String {
            switch self {
            case .ansiQuote: return "A placeholder cannot stand inside $'…'. Use \"…\" or '…' instead."
            case .backtick: return "A placeholder cannot stand between backticks. Use $(…) instead."
            case .hereDocument: return "A placeholder cannot stand in or after a here-document (<<)."
            case .comment: return "A placeholder stands in a comment (after #)."
            case .backslash: return "A placeholder cannot follow a backslash. Put it in quotes instead."
            case .dollar: return "A placeholder cannot follow a $ sign."
            case .arithmetic:
                return "A placeholder cannot stand where the shell works out a number: in $((…)), ((…)), $[…], "
                    + "in the subscript of $name[…], or in a test that compares numbers (-eq, -lt …)."
            case .parameterExpansion:
                return "A placeholder cannot stand in or after a ${…} expression with an operator."
            case .caseInSubstitution: return "A placeholder cannot stand after a case statement inside $(…)."
            }
        }
    }

    private enum Frame: Equatable {
        /// Commands: the line itself, or the inside of `$(…)`. `parens` counts the open `(`.
        case code(parens: Int)
        case doubleQuote, singleQuote, ansiQuote, backtick
        /// `${…}`.
        case braces
        /// `$((…))`.
        case arithmetic(parens: Int)
    }

    private var frames: [Frame] = [.code(parens: 0)]
    /// The character before was a backslash that takes the next one's meaning.
    private var escaped = false
    /// The character before was a `$` that may begin an expansion.
    private var dollar = false
    /// The character before was the `(` of a `$(`: another `(` makes it arithmetic.
    private var openedSubstitution = false
    /// The character before was a `(` of the commands.
    private var openedParenthesis = false
    /// How many `<` came directly before.
    private var lessThans = 0
    private var comment = false
    /// The word of the commands being read, while it can still be the keyword `case`.
    private var keyword: String? = ""
    /// Nothing of the present word has been written, not even a quote: a `#` begins a comment.
    private var tokenStart = true
    /// The present word has no content so far (an opening quote is none).
    private var wordEmpty = true
    /// Set when the line can no longer be followed; every later value is refused.
    private(set) var poisoned: Refusal?
    /// The characters before were a `$` and the letters of a name: a `[` begins its subscript.
    private var variableName = false
    /// Inside a test (`[[ … ]]`, `[ … ]`, `test …`): whether it holds a value, and whether it
    /// compares numbers (`-eq`, `-lt` …).
    private var test: (hasValue: Bool, comparesNumbers: Bool)?
    /// A test held a value and compared numbers: the shell works such operands out as
    /// arithmetic. The whole line is then refused, wherever the value stood in the test.
    private(set) var hasArithmeticTest = false

    /// Whether what is written next begins a word of the line (also right after the user's
    /// opening quote).
    var isAtWordStart: Bool {
        guard wordEmpty, place != nil else { return false }
        return true
    }

    /// Where a value written now would stand; nil where none can.
    var place: Place? { try? check().get() }

    private func check() -> Result<Place, Refusal> {
        if let poisoned { return .failure(poisoned) }
        if comment { return .failure(.comment) }
        if escaped { return .failure(.backslash) }
        if dollar { return .failure(.dollar) }
        if lessThans == 2 { return .failure(.hereDocument) }
        switch frames[frames.count - 1] {
        case .code: return .success(.word)
        case .doubleQuote: return .success(.doubleQuoted)
        case .singleQuote: return .success(.singleQuoted)
        case .ansiQuote: return .failure(.ansiQuote)
        case .backtick: return .failure(.backtick)
        case .braces: return .failure(.parameterExpansion)
        case .arithmetic: return .failure(.arithmetic)
        }
    }

    /// A value stands here. Returns its place, or why it cannot stand here.
    @discardableResult
    mutating func feedValue() -> Result<Place, Refusal> {
        let result = check()
        if case .success = result {
            content()
            openedSubstitution = false
            openedParenthesis = false
            lessThans = 0
            variableName = false
            if test != nil {
                test?.hasValue = true
                if test?.comparesNumbers == true { hasArithmeticTest = true }
            }
        }
        return result
    }

    mutating func feed(_ text: String) {
        for scalar in text.unicodeScalars { feed(scalar) }
    }

    private mutating func startWord() {
        tokenStart = true
        wordEmpty = true
        keyword = ""
    }

    private mutating func content() {
        tokenStart = false
        wordEmpty = false
        keyword = nil
    }

    /// The end of a word of the commands. A `case` inside `$(…)` has patterns that end in a
    /// `)` of their own, which cannot be told from the end of the `$(…)`.
    private mutating func endWord() {
        switch keyword {
        case "case" where frames.count > 1: poisoned = .caseInSubstitution
        case "[[", "[", "test": if test == nil { test = (false, false) }
        case "]]", "]": test = nil
        case "-eq", "-ne", "-lt", "-le", "-gt", "-ge":
            if test != nil {
                test?.comparesNumbers = true
                if test?.hasValue == true { hasArithmeticTest = true }
            }
        default: break
        }
    }

    private mutating func push(_ frame: Frame) { frames.append(frame) }

    private mutating func pop() {
        if frames.count > 1 { frames.removeLast() }
        // Back in the word that held the quote or the substitution.
        tokenStart = false
        keyword = nil
    }

    private static func isSimpleParameterCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "_", "@", "*", "#", "?", "!", "$": return true
        default: return false
        }
    }

    mutating func feed(_ scalar: Unicode.Scalar) {
        guard poisoned == nil else { return }
        if comment {
            if scalar == "\n" {
                comment = false
                startWord()
            }
            return
        }
        let (wasDollar, wasSubstitution, wasParenthesis, hadLessThans) = (
            dollar, openedSubstitution, openedParenthesis, lessThans
        )
        dollar = false
        openedSubstitution = false
        openedParenthesis = false
        lessThans = 0
        // `$name[…]`: in zsh the subscript of an array is arithmetic.
        let wasVariableName = variableName
        variableName = false
        switch frames[frames.count - 1] {
        case .code, .doubleQuote:
            if !escaped {
                let isLetter =
                    (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
                    || scalar == "_"
                let isDigit = scalar.value >= 48 && scalar.value <= 57
                if (wasDollar && isLetter) || (wasVariableName && (isLetter || isDigit)) {
                    variableName = true
                } else if wasVariableName, scalar == "[" {
                    poisoned = .arithmetic
                    return
                }
            }
        default: break
        }

        switch frames[frames.count - 1] {
        case .singleQuote:
            if scalar == "'" { pop() } else { wordEmpty = false }

        case .ansiQuote:
            wordEmpty = false
            if escaped { escaped = false } else if scalar == "\\" { escaped = true } else if scalar == "'" { pop() }

        case .backtick:
            wordEmpty = false
            if escaped { escaped = false } else if scalar == "\\" { escaped = true } else if scalar == "`" { pop() }

        case .braces:
            if scalar == "}" {
                pop()
                wordEmpty = false
            } else if !ShellContext.isSimpleParameterCharacter(scalar) {
                poisoned = .parameterExpansion
            }

        case .arithmetic(let parens):
            switch scalar {
            case "(": frames[frames.count - 1] = .arithmetic(parens: parens + 1)
            case ")":
                if parens == 0 {
                    pop()
                    wordEmpty = false
                } else {
                    frames[frames.count - 1] = .arithmetic(parens: parens - 1)
                }
            case "\"", "'", "`", "\\": poisoned = .arithmetic
            default: break
            }

        case .doubleQuote:
            if escaped {
                escaped = false
                wordEmpty = false
                return
            }
            if wasDollar {
                switch scalar {
                case "(":
                    push(.code(parens: 0))
                    openedSubstitution = true
                    startWord()
                    return
                case "{":
                    push(.braces)
                    return
                case "[":
                    poisoned = .arithmetic
                    return
                default: break
                }
            }
            switch scalar {
            case "\\": escaped = true
            case "\"": pop()
            case "`":
                push(.backtick)
                wordEmpty = false
            case "$":
                dollar = true
                wordEmpty = false
            default: wordEmpty = false
            }

        case .code(let parens):
            if escaped {
                escaped = false
                content()
                return
            }
            if hadLessThans == 2, scalar != "<" {
                poisoned = .hereDocument
                return
            }
            if wasDollar {
                switch scalar {
                case "(":
                    push(.code(parens: 0))
                    openedSubstitution = true
                    startWord()
                    return
                case "{":
                    push(.braces)
                    return
                case "'":
                    push(.ansiQuote)
                    return
                case "[":
                    poisoned = .arithmetic
                    return
                default: break
                }
            }
            if wasSubstitution, scalar == "(" {
                frames[frames.count - 1] = .arithmetic(parens: 1)
                return
            }
            switch scalar {
            case "\\":
                escaped = true
                tokenStart = false
                keyword = nil
            case "'":
                push(.singleQuote)
                tokenStart = false
                keyword = nil
            case "\"":
                push(.doubleQuote)
                tokenStart = false
                keyword = nil
            case "`":
                content()
                push(.backtick)
            case "$":
                content()
                dollar = true
            case "#":
                if tokenStart { comment = true } else { content() }
            case " ", "\t", ">":
                endWord()
                startWord()
            case "\n", ";", "&", "|":
                endWord()
                startWord()
                // The command ends, and a `test` with it.
                test = nil
            case "<":
                endWord()
                startWord()
                lessThans = hadLessThans + 1
            case "(":
                endWord()
                // `((` is the arithmetic command.
                if wasParenthesis {
                    poisoned = .arithmetic
                    return
                }
                frames[frames.count - 1] = .code(parens: parens + 1)
                startWord()
                openedParenthesis = true
            case ")":
                endWord()
                guard poisoned == nil else { return }
                test = nil
                if parens == 0, frames.count > 1 {
                    pop()
                    wordEmpty = false
                } else {
                    frames[frames.count - 1] = .code(parens: max(0, parens - 1))
                    startWord()
                }
            default:
                tokenStart = false
                wordEmpty = false
                if let word = keyword { keyword = word.unicodeScalars.count < 4 ? word + String(scalar) : nil }
            }
        }
    }
}

/// A command line with its data apart: the text a shell is given, in which every value is a
/// reference to a variable, and the values themselves.
struct ShellScript: Equatable {
    /// The line with a reference in place of every value.
    var line: String
    var values: [String]

    /// What the shell runs: the values, handed over as arguments of the shell, are first given
    /// names of their own (so `set --`, `shift` and functions cannot move them), then the line.
    var text: String {
        guard !values.isEmpty else { return line }
        let names = values.indices.map { "\(ShellLine.variable($0))=\"${\($0 + 1)}\"" }.joined(separator: " ")
        return names + "\n" + line
    }

    /// The arguments for a shell after its options: `-c`'s script, a name, and the values.
    var arguments: [String] { [text, "afm"] + values }
}

/// Turns an expanded text into what a shell runs and into what the user reads.
enum ShellLine {
    private static let variablePrefix = "__afm_"

    static func variable(_ index: Int) -> String { variablePrefix + String(index + 1) }

    /// The reference to value number `index` at a place of the line.
    private static func reference(_ index: Int, at place: ShellContext.Place) -> String {
        let name = "${" + variable(index) + "}"
        switch place {
        case .word: return "\"" + name + "\""
        case .doubleQuoted: return name
        // The user's quote is closed, the reference stands in double quotes, the quote opens again.
        case .singleQuoted: return "'\"" + name + "\"'"
        }
    }

    /// The line for a shell. No value becomes part of its text: each is passed as data and
    /// referred to where its placeholder stood. Fails where a reference cannot be written safely.
    static func script(_ pieces: [ExpandedPiece]) -> Result<ShellScript, ShellContext.Refusal> {
        var lexer = ShellContext()
        var line = ""
        var values: [String] = []
        for piece in pieces {
            switch piece {
            case .text(let text), .raw(let text):
                line += text
                lexer.feed(text)
            case .value(let value):
                switch lexer.feedValue() {
                case .failure(let refusal): return .failure(refusal)
                case .success(let place):
                    line += reference(values.count, at: place)
                    values.append(value)
                }
            }
        }
        // A test that compares numbers works its operands out as arithmetic.
        if lexer.hasArithmeticTest { return .failure(.arithmetic) }
        return .success(ShellScript(line: line, values: values))
    }

    /// The line as one readable text, the values written into it and quoted where they stand.
    /// For showing, for commands of the program and for `cd`: never for a shell.
    static func display(_ pieces: [ExpandedPiece]) -> String {
        var lexer = ShellContext()
        var line = ""
        for (index, piece) in pieces.enumerated() {
            switch piece {
            case .text(let text), .raw(let text):
                line += text
                lexer.feed(text)
            case .value(let value):
                let startsWord = lexer.isAtWordStart
                switch lexer.feedValue() {
                case .success(.word):
                    if value.isEmpty {
                        // An empty value that is a word of its own stays one.
                        if startsWord, endsWord(after: index, in: pieces) { line += "\"\"" }
                    } else {
                        line += ShellWords.needsQuoting(value) ? ShellWords.quoted(value) : value
                    }
                case .success(.singleQuoted): line += ShellWords.singleQuoteEscaped(value)
                case .success(.doubleQuoted), .failure: line += ShellWords.escaped(value)
                }
            }
        }
        return line
    }

    private static func endsWord(after index: Int, in pieces: [ExpandedPiece]) -> Bool {
        guard index + 1 < pieces.count else { return true }
        guard case .text(let text) = pieces[index + 1], let first = text.unicodeScalars.first else { return false }
        return first == " " || first == "\t" || first == "\n"
    }

    // MARK: Asking for the parameters

    /// Whether a value may be shown, and typed over, as part of the line: it holds nothing
    /// that a shell or the placeholders give a meaning to, so as text it says what it says.
    static func isTame(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first, let last = value.unicodeScalars.last, first != " ", last != " "
        else { return false }
        return value.unicodeScalars.allSatisfy {
            $0 == " " || ($0 != "%" && $0 != "^" && !ShellWords.needsQuoting(String($0)))
        }
    }

    /// What the user is shown when the parameters begin with `?`: the line with harmless
    /// values written out, and every other value as the reference a shell is given, which is
    /// explained in `legend`. The user may change the line; `pieces(fromPrompt:values:)` reads
    /// it back.
    static func prompt(_ pieces: [ExpandedPiece]) -> (text: String, values: [String], legend: String) {
        var lexer = ShellContext()
        var line = ""
        var values: [String] = []
        var legend: [String] = []
        for piece in pieces {
            switch piece {
            case .text(let text), .raw(let text):
                line += text
                lexer.feed(text)
            case .value(let value):
                let place = try? lexer.feedValue().get()
                if let place, isTame(value) {
                    // As a word of its own it is quoted, so that it can be no keyword and no alias.
                    line += place == .word ? ShellWords.quoted(value) : value
                } else {
                    line += place.map { reference(values.count, at: $0) } ?? "${" + variable(values.count) + "}"
                    if legend.count < 12 {
                        legend.append("${\(variable(values.count))} = \(DisplayText.oneLine(value, limit: 120))")
                    }
                    values.append(value)
                }
            }
        }
        if values.count > legend.count { legend.append("… and \(values.count - legend.count) more") }
        return (line, values, legend.joined(separator: "\n"))
    }

    /// The line the user made of a prompt: its references become the values again, everything
    /// else is text the user approved.
    static func pieces(fromPrompt text: String, values: [String]) -> [ExpandedPiece] {
        var pieces: [ExpandedPiece] = []
        var rest = Substring(text)
        let opening = "${" + variablePrefix
        while let found = rest.range(of: opening, options: .literal) {
            let after = rest[found.upperBound...]
            let digits = after.unicodeScalars.prefix { $0.value >= 48 && $0.value <= 57 }
            let end = after.unicodeScalars.index(after.unicodeScalars.startIndex, offsetBy: digits.count)
            guard digits.count <= 9, let number = Int(String(String.UnicodeScalarView(digits))), number >= 1,
                number <= values.count,
                end < after.unicodeScalars.endIndex, after.unicodeScalars[end] == "}"
            else {
                pieces.append(.text(String(rest[..<found.upperBound])))
                rest = after
                continue
            }
            pieces.append(.text(String(rest[..<found.lowerBound])))
            pieces.append(.value(values[number - 1]))
            rest = after[after.unicodeScalars.index(after: end)...]
        }
        pieces.append(.text(String(rest)))
        return ParameterExpander.trimmed(pieces)
    }
}
