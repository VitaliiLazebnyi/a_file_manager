/// Reading the user's text character by character.
extension ShellContext {
    /// What the character before left behind, for the present one to act on.
    private struct Before {
        /// It was a `$` that may begin an expansion.
        let dollar: Bool
        /// It was the `(` of a `$(`.
        let substitution: Bool
        /// It was a `(` of the commands.
        let parenthesis: Bool
        /// How many `<` came directly before.
        let lessThans: Int
        /// It ended a `$` with the letters of a name.
        let variableName: Bool
    }

    /// Whether a character may stand in a `${…}` that only names a parameter.
    private static func isSimpleParameterCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "_", "@", "*", "#", "?", "!", "$":
            return true

        default:
            return false
        }
    }

    /// Reads one character the user wrote.
    internal mutating func feed(_ scalar: Unicode.Scalar) {
        guard poisoned == nil else {
            return
        }
        if comment {
            feedComment(scalar)
            return
        }
        let before = takeBefore()
        guard followName(scalar, before) else {
            return
        }
        read(scalar, before)
    }

    /// A comment ends at the end of the line.
    private mutating func feedComment(_ scalar: Unicode.Scalar) {
        if scalar == "\n" {
            comment = false
            startWord()
        }
    }

    /// What the character before left, which is cleared for the present one.
    private mutating func takeBefore() -> Before {
        let before = Before(
            dollar: dollar,
            substitution: openedSubstitution,
            parenthesis: openedParenthesis,
            lessThans: lessThans,
            variableName: variableName
        )
        dollar = false
        openedSubstitution = false
        openedParenthesis = false
        lessThans = 0
        variableName = false
        return before
    }

    /// Follows the letters of a variable name: `$name[…]` is refused, since in zsh the subscript
    /// of an array is arithmetic.
    ///
    /// False when the line is refused here.
    private mutating func followName(_ scalar: Unicode.Scalar, _ before: Before) -> Bool {
        switch frame {
        case .code, .doubleQuote:
            break

        default:
            return true
        }
        guard !escaped else {
            return true
        }
        let isLetter =
            (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122) || scalar == "_"
        let isDigit = scalar.value >= 48 && scalar.value <= 57
        if (before.dollar && isLetter) || (before.variableName && (isLetter || isDigit)) {
            variableName = true
        } else if before.variableName, scalar == "[" {
            poison(.arithmetic)
            return false
        }
        return true
    }

    /// The character in the frame it stands in.
    private mutating func read(_ scalar: Unicode.Scalar, _ before: Before) {
        switch frame {
        case .singleQuote:
            feedSingleQuoted(scalar)

        case .ansiQuote:
            feedEscaping(scalar, closedBy: "'")

        case .backtick:
            feedEscaping(scalar, closedBy: "`")

        case .braces:
            feedBraces(scalar)

        case .arithmetic(let parens):
            feedArithmetic(scalar, parens: parens)

        case .doubleQuote:
            feedDoubleQuoted(scalar, before)

        case .code(let parens):
            feedCode(scalar, parens: parens, before)
        }
    }

    /// Between single quotes only the closing quote means something.
    private mutating func feedSingleQuoted(_ scalar: Unicode.Scalar) {
        if scalar == "'" {
            pop()
        } else {
            wordEmpty = false
        }
    }

    /// Inside `$'…'` or backticks: a backslash escapes the next character, `closing` ends it.
    private mutating func feedEscaping(_ scalar: Unicode.Scalar, closedBy closing: Unicode.Scalar) {
        wordEmpty = false
        if escaped {
            escaped = false
        } else if scalar == "\\" {
            escaped = true
        } else if scalar == closing {
            pop()
        }
    }

    /// Inside `${…}`: a plain parameter name is followed, an operator is refused.
    private mutating func feedBraces(_ scalar: Unicode.Scalar) {
        if scalar == "}" {
            pop()
            wordEmpty = false
        } else if !Self.isSimpleParameterCharacter(scalar) {
            poison(.parameterExpansion)
        }
    }

    /// Inside `$((…))`: the parentheses are counted; a quote or a backslash is refused.
    private mutating func feedArithmetic(_ scalar: Unicode.Scalar, parens: Int) {
        switch scalar {
        case "(":
            replaceFrame(with: .arithmetic(parens: parens + 1))

        case ")":
            if parens == 0 {
                pop()
                wordEmpty = false
            } else {
                replaceFrame(with: .arithmetic(parens: parens - 1))
            }

        case "\"", "'", "`", "\\":
            poison(.arithmetic)

        default:
            break
        }
    }

    /// Between double quotes: escapes, the closing quote, and what a `$` or a backtick begins.
    private mutating func feedDoubleQuoted(_ scalar: Unicode.Scalar, _ before: Before) {
        if escaped {
            escaped = false
            wordEmpty = false
            return
        }
        if before.dollar, openExpansion(after: scalar, allowsANSIQuote: false) {
            return
        }
        switch scalar {
        case "\\":
            escaped = true

        case "\"":
            pop()

        case "`":
            push(.backtick)
            wordEmpty = false

        case "$":
            dollar = true
            wordEmpty = false

        default:
            wordEmpty = false
        }
    }

    /// What a `$` begins with the character after it: `$(…)`, `${…}`, `$'…'` (outside double
    /// quotes) or the refused `$[…]`.
    ///
    /// False when the character begins none of them.
    private mutating func openExpansion(after scalar: Unicode.Scalar, allowsANSIQuote: Bool) -> Bool {
        switch scalar {
        case "(":
            push(.code(parens: 0))
            openedSubstitution = true
            startWord()
            return true

        case "{":
            push(.braces)
            return true

        case "'" where allowsANSIQuote:
            push(.ansiQuote)
            return true

        case "[":
            poison(.arithmetic)
            return true

        default:
            return false
        }
    }

    /// In the commands: what the character before began comes first.
    private mutating func feedCode(_ scalar: Unicode.Scalar, parens: Int, _ before: Before) {
        if escaped {
            escaped = false
            content()
            return
        }
        if before.lessThans == 2, scalar != "<" {
            poison(.hereDocument)
            return
        }
        if before.dollar, openExpansion(after: scalar, allowsANSIQuote: true) {
            return
        }
        if before.substitution, scalar == "(" {
            replaceFrame(with: .arithmetic(parens: 1))
            return
        }
        codeCharacter(scalar, parens: parens, before)
    }

    /// A character of the commands on its own.
    private mutating func codeCharacter(_ scalar: Unicode.Scalar, parens: Int, _ before: Before) {
        switch scalar {
        case "\\", "'", "\"":
            openQuote(scalar)

        case "`":
            content()
            push(.backtick)

        case "$":
            content()
            dollar = true

        case "#":
            if tokenStart { comment = true } else { content() }

        case " ", "\t", ">", "\n", ";", "&", "|", "<":
            separator(scalar, before)

        case "(":
            openParenthesis(parens: parens, before)

        case ")":
            closeParenthesis(parens: parens)

        default:
            wordCharacter(scalar)
        }
    }

    /// A backslash, or the opening quote of a single- or double-quoted part of the word.
    private mutating func openQuote(_ scalar: Unicode.Scalar) {
        switch scalar {
        case "\\":
            escaped = true

        case "'":
            push(.singleQuote)

        default:
            push(.doubleQuote)
        }
        tokenStart = false
        keyword = nil
    }

    /// A blank or an operator ends the word; the end of a command ends a `test` with it.
    private mutating func separator(_ scalar: Unicode.Scalar, _ before: Before) {
        endWord()
        startWord()
        switch scalar {
        case "\n", ";", "&", "|":
            // The command ends, and a `test` with it.
            test = nil

        case "<":
            lessThans = before.lessThans + 1

        default:
            break
        }
    }

    /// A `(` of the commands; `((` is the arithmetic command and refused.
    private mutating func openParenthesis(parens: Int, _ before: Before) {
        endWord()
        if before.parenthesis {
            poison(.arithmetic)
            return
        }
        replaceFrame(with: .code(parens: parens + 1))
        startWord()
        openedParenthesis = true
    }

    /// A `)` of the commands: the end of a `$(…)` or of a group.
    private mutating func closeParenthesis(parens: Int) {
        endWord()
        guard poisoned == nil else {
            return
        }
        test = nil
        if parens == 0, frames.count > 1 {
            pop()
            wordEmpty = false
        } else {
            replaceFrame(with: .code(parens: max(0, parens - 1)))
            startWord()
        }
    }

    /// Any other character: part of the word, and maybe of a keyword.
    private mutating func wordCharacter(_ scalar: Unicode.Scalar) {
        tokenStart = false
        wordEmpty = false
        if let word = keyword { keyword = word.unicodeScalars.count < 4 ? word + String(scalar) : nil }
    }
}
