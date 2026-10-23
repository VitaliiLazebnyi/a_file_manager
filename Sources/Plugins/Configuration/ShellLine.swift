import Foundation

/// Turns an expanded text into what a shell runs and into what the user reads.
internal enum ShellLine {
    /// What the names of the variables that hold the values begin with.
    private static let variablePrefix = "__afm_"

    /// The name of the variable that holds value number `index` (counted from 0).
    internal static func variable(_ index: Int) -> String { variablePrefix + String(index + 1) }

    /// The reference to value number `index` at a place of the line.
    private static func reference(_ index: Int, at place: ShellContext.Place) -> String {
        let name = "${" + variable(index) + "}"
        switch place {
        case .word:
            return "\"" + name + "\""

        case .doubleQuoted:
            return name

        // The user's quote is closed, the reference stands in double quotes, the quote opens again.
        case .singleQuoted:
            return "'\"" + name + "\"'"
        }
    }

    /// The line for a shell.
    ///
    /// No value becomes part of its text: each is passed as data and referred to where its
    /// placeholder stood. Fails where a reference cannot be written safely.
    internal static func script(_ pieces: [ExpandedPiece]) -> Result<ShellScript, ShellContext.Refusal> {
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
                case .failure(let refusal):
                    return .failure(refusal)

                case .success(let place):
                    line += reference(values.count, at: place)
                    values.append(value)
                }
            }
        }
        // A test that compares numbers works its operands out as arithmetic.
        if lexer.hasArithmeticTest {
            return .failure(.arithmetic)
        }
        return .success(ShellScript(line: line, values: values))
    }

    /// The line as one readable text, the values written into it and quoted where they stand.
    ///
    /// For showing, for commands of the program and for `cd`: never for a shell.
    internal static func display(_ pieces: [ExpandedPiece]) -> String {
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

                case .success(.singleQuoted):
                    line += ShellWords.singleQuoteEscaped(value)

                case .success(.doubleQuoted), .failure:
                    line += ShellWords.escaped(value)
                }
            }
        }
        return line
    }

    private static func endsWord(after index: Int, in pieces: [ExpandedPiece]) -> Bool {
        guard index + 1 < pieces.count else {
            return true
        }
        guard case .text(let text) = pieces[index + 1], let first = text.unicodeScalars.first else {
            return false
        }
        return first == " " || first == "\t" || first == "\n"
    }

    // MARK: Asking for the parameters

    /// Whether a value may be shown, and typed over, as part of the line: it holds nothing
    /// that a shell or the placeholders give a meaning to, so as text it says what it says.
    internal static func isTame(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first, let last = value.unicodeScalars.last, first != " ", last != " "
        else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar == " " || (scalar != "%" && scalar != "^" && !ShellWords.needsQuoting(String(scalar)))
        }
    }

    /// What the user is shown when the parameters begin with `?`: the line with harmless
    /// values written out, and every other value as the reference a shell is given, which is
    /// explained in `legend`.
    ///
    /// The user may change the line; `pieces(fromPrompt:values:)` reads it back.
    internal static func prompt(_ pieces: [ExpandedPiece]) -> ShellPrompt {
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
        return ShellPrompt(text: line, values: values, legend: legend.joined(separator: "\n"))
    }

    /// The line the user made of a prompt: its references become the values again, everything
    /// else is text the user approved.
    internal static func pieces(fromPrompt text: String, values: [String]) -> [ExpandedPiece] {
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
