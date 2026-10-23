/// Follows a command line the way a shell reads it, far enough to say where a value may stand
/// and how a reference to it must be written there.
///
/// It reads only what the user wrote: values are announced with `feedValue()` and never looked at.
///
/// It knows single and double quotes, `$'…'`, backslashes, backticks, `$(…)`, `$((…))`,
/// `${…}`, comments and the `<<` of a here-document. Where it cannot be sure of the place
/// (inside `$'…'`, backticks, a comment, after `<<`, after a construct it does not follow), it
/// refuses: the command is then not run, which is always safe. It also refuses the places
/// where a shell works a value out as arithmetic, because there a value is read as an
/// expression again and can run a command: `$((…))`, `((…))`, `$[…]`, the subscript of
/// `$name[…]`, and a test (`[[ … ]]`, `[ … ]`, `test`) that compares numbers. Works on Unicode
/// scalars, as a shell works on bytes: every character that means something to a shell is ASCII.
internal struct ShellContext {
    /// Where a value stands.
    internal enum Place: Equatable {
        /// Between the user's double quotes.
        case doubleQuoted
        /// Between the user's single quotes.
        case singleQuoted
        /// In a word of the line, outside every quote.
        case word
    }

    /// What the line is inside of at the present character.
    internal enum Frame: Equatable {
        /// Inside `$'…'`.
        case ansiQuote
        /// `$((…))`; `parens` counts the open `(` inside it.
        case arithmetic(parens: Int)
        /// Between backticks.
        case backtick
        /// `${…}`.
        case braces
        /// Commands: the line itself, or the inside of `$(…)`. `parens` counts the open `(`.
        case code(parens: Int)
        /// Between double quotes.
        case doubleQuote
        /// Between single quotes.
        case singleQuote
    }

    /// What the line is inside of, outermost first: the commands of the line at the bottom.
    internal var frames: [Frame] = [.code(parens: 0)]
    /// The character before was a backslash that takes the next one's meaning.
    internal var escaped = false
    /// The character before was a `$` that may begin an expansion.
    internal var dollar = false
    /// The character before was the `(` of a `$(`: another `(` makes it arithmetic.
    internal var openedSubstitution = false
    /// The character before was a `(` of the commands.
    internal var openedParenthesis = false
    /// How many `<` came directly before.
    internal var lessThans = 0
    /// The line is in a comment until the next line break.
    internal var comment = false
    /// The word of the commands being read, while it can still be the keyword `case`.
    internal var keyword: String? = ""
    /// Nothing of the present word has been written, not even a quote: a `#` begins a comment.
    internal var tokenStart = true
    /// The present word has no content so far (an opening quote is none).
    internal var wordEmpty = true
    /// Set when the line can no longer be followed; every later value is refused.
    internal private(set) var poisoned: Refusal?
    /// The characters before were a `$` and the letters of a name: a `[` begins its subscript.
    internal var variableName = false
    /// Inside a test (`[[ … ]]`, `[ … ]`, `test …`): whether it holds a value, and whether it
    /// compares numbers (`-eq`, `-lt` …).
    internal var test: (hasValue: Bool, comparesNumbers: Bool)?
    /// A test held a value and compared numbers: the shell works such operands out as
    /// arithmetic.
    ///
    /// The whole line is then refused, wherever the value stood in the test.
    internal private(set) var hasArithmeticTest = false

    /// Whether what is written next begins a word of the line (also right after the user's
    /// opening quote).
    internal var isAtWordStart: Bool {
        guard wordEmpty, place != nil else {
            return false
        }
        return true
    }

    /// Where a value written now would stand; nil where none can.
    internal var place: Place? { try? check().get() }

    /// The frame of the present character.
    internal var frame: Frame { frames[frames.count - 1] }

    /// Where a value stands in `frame`, or why none can.
    private static func place(in frame: Frame) -> Result<Place, Refusal> {
        switch frame {
        case .code:
            return .success(.word)

        case .doubleQuote:
            return .success(.doubleQuoted)

        case .singleQuote:
            return .success(.singleQuoted)

        case .ansiQuote:
            return .failure(.ansiQuote)

        case .backtick:
            return .failure(.backtick)

        case .braces:
            return .failure(.parameterExpansion)

        case .arithmetic:
            return .failure(.arithmetic)
        }
    }

    /// Where a value written now would stand, or why none can.
    private func check() -> Result<Place, Refusal> {
        if let poisoned {
            return .failure(poisoned)
        }
        if comment {
            return .failure(.comment)
        }
        if escaped {
            return .failure(.backslash)
        }
        if dollar {
            return .failure(.dollar)
        }
        if lessThans == 2 {
            return .failure(.hereDocument)
        }
        return Self.place(in: frame)
    }

    /// A value stands here.
    ///
    /// Returns its place, or why it cannot stand here.
    @discardableResult
    internal mutating func feedValue() -> Result<Place, Refusal> {
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

    /// Reads text the user wrote.
    internal mutating func feed(_ text: String) {
        for scalar in text.unicodeScalars { feed(scalar) }
    }

    /// From here on the line cannot be followed: every later value is refused for `refusal`.
    internal mutating func poison(_ refusal: Refusal) {
        poisoned = refusal
    }

    /// A new word of the commands begins.
    internal mutating func startWord() {
        tokenStart = true
        wordEmpty = true
        keyword = ""
    }

    /// The present word has content: no comment, no keyword can begin in it any more.
    internal mutating func content() {
        tokenStart = false
        wordEmpty = false
        keyword = nil
    }

    /// The end of a word of the commands.
    ///
    /// A `case` inside `$(…)` has patterns that end in a `)` of their own, which cannot be told
    /// from the end of the `$(…)`.
    internal mutating func endWord() {
        switch keyword {
        case "case" where frames.count > 1:
            poisoned = .caseInSubstitution

        case "[[", "[", "test":
            if test == nil { test = (false, false) }

        case "]]", "]":
            test = nil

        case "-eq", "-ne", "-lt", "-le", "-gt", "-ge":
            if test != nil {
                test?.comparesNumbers = true
                if test?.hasValue == true { hasArithmeticTest = true }
            }

        default:
            break
        }
    }

    /// Enters a quote, a substitution or an expansion.
    internal mutating func push(_ frame: Frame) { frames.append(frame) }

    /// Leaves the innermost quote, substitution or expansion.
    internal mutating func pop() {
        if frames.count > 1 { frames.removeLast() }
        // Back in the word that held the quote or the substitution.
        tokenStart = false
        keyword = nil
    }

    /// Changes the innermost frame (the count of open parentheses, or code into arithmetic).
    internal mutating func replaceFrame(with frame: Frame) {
        frames[frames.count - 1] = frame
    }
}
