import AFMKernel
import Foundation

/// One pass of `ParameterExpander` over a text.
///
/// Placeholders that follow each other directly (`%P%N`) form one word and one value.
internal struct ExpansionRun {
    /// A character the user wrote, or a piece that came out of an earlier expansion.
    internal enum Token {
        /// A piece passed on as it is.
        case piece(ExpandedPiece)
        /// A character of the text, to be read.
        case scalar(Unicode.Scalar)
    }

    /// How a list file is written.
    internal enum ListEncoding {
        /// UTF-8 without a mark (`%L`, `%F`).
        case plain
        /// UTF-16 little-endian with a byte order mark (`%WL`, `%WF`).
        case utf16WithMark
        /// UTF-8 with a byte order mark (`%UL`, `%UF`).
        case utf8WithMark
    }

    /// What the placeholders refer to.
    internal let context: ExpansionContext
    /// The text to read.
    internal let tokens: [Token]
    /// The next token to read.
    internal var position = 0
    /// What was expanded so far.
    internal var pieces: [ExpandedPiece] = []
    /// The text written since the last value.
    internal var literal = String.UnicodeScalarView()
    /// Follows the line as a shell would read it: where a word begins, which quote is open.
    internal var lexer = ShellContext()
    /// The values of the placeholders read since the last literal character.
    internal var word: String?
    /// The word so far is a path code alone, which a following `%S` applies to every name.
    internal var wordIsPath = false
    /// Where the double quote the user opened last began: how many pieces there were, and
    /// how the line stood before it.
    internal var openQuote: (pieces: Int, lexer: ShellContext)?
    /// A name code met a panel without a name under the cursor.
    internal var missingName = false
    /// Why the command must not run, if something says so.
    internal var problem: String?
    /// After `%X`: the codes mean the left and right panel instead of source and target.
    internal var leftRight = false
    /// After an odd number of `%q`: double quotes are taken out of what the user typed.
    internal var stripsQuotes = false
    /// The list file the first list code asked for.
    internal var listFile: ListFile?
    /// A list code was read: only the first one counts.
    internal var listWasRequested = false
    /// An `%A` code used the arguments.
    internal var usedArguments = false
    /// Values are passed as data; `%Q` anywhere in the text pastes them into the line instead.
    internal let quotesAutomatically: Bool
    /// `%Y`: with nothing marked, `%S` and the lists hold no name rather than the one under the cursor.
    internal let emptyWhenUnselected: Bool
    /// `%y`: with nothing marked, a list code is dropped.
    internal let dropsListWhenUnselected: Bool
    /// `%a`: a list holds the marked names of the other panel too.
    internal let includesTargetSelection: Bool

    /// The panel the codes for the source mean (the left one after `%X`).
    internal var first: PanelSnapshot { leftRight ? context.left : context.source }
    /// The panel the codes for the target mean (the right one after `%X`).
    internal var second: PanelSnapshot { leftRight ? context.right : context.target }
    /// The next character of the text; nil at the end and in front of a value.
    internal var next: Unicode.Scalar? { scalar(at: position) }
    /// Whether what is written now stands inside double quotes of the line.
    internal var isInsideDoubleQuotes: Bool { lexer.place == .doubleQuoted }

    /// A run over `tokens`; the flags (`%Q`, `%Y`, `%y`, `%a`) count wherever they stand.
    internal init(context: ExpansionContext, tokens: [Token]) {
        self.context = context
        self.tokens = tokens
        var flags = Set<Unicode.Scalar>()
        Self.codes(of: tokens) { flags.insert($0) }
        quotesAutomatically = !flags.contains("Q")
        emptyWhenUnselected = flags.contains("Y")
        dropsListWhenUnselected = flags.contains("y")
        includesTargetSelection = flags.contains("a")
    }

    /// The tokens of a text: the characters of its texts, and its values as they are.
    internal static func tokens(of pieces: [ExpandedPiece]) -> [Token] {
        var result: [Token] = []
        for piece in pieces {
            if case .text(let text) = piece {
                result.append(contentsOf: text.unicodeScalars.map(Token.scalar))
            } else {
                result.append(.piece(piece))
            }
        }
        return result
    }

    /// Calls `found` with the letter of every `%<letter>` code; `%%` is the percent sign.
    internal static func codes(of tokens: [Token], _ found: (Unicode.Scalar) -> Void) {
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

    /// The character at `index`; nil at the end and at a value.
    internal func scalar(at index: Int) -> Unicode.Scalar? {
        guard index < tokens.count, case .scalar(let scalar) = tokens[index] else {
            return nil
        }
        return scalar
    }

    /// Reads the whole text into `pieces`.
    internal mutating func expand() {
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
            placeholder(code)
        }
        flushWord()
        flushLiteral()
    }

    /// The code after a `%`, by its kind; an unknown one stays in the text as it was written.
    private mutating func placeholder(_ code: Unicode.Scalar) {
        switch code {
        case "%":
            literal("%")

        case "|":
            environmentVariable()

        case "P", "p", "T", "t", "N", "n", "v", "V", "M", "m", "O", "o", "E", "e", "S", "s", "R", "r":
            panelCode(code)

        case "B", "b":
            directoryName()

        case "C", "c":
            comparedFile(code)

        case "A":
            arguments()

        case "L", "l", "D", "F", "f", "d", "U", "W":
            listCode(code)

        case "X", "x", "q", "Y", "y", "Z", "Q", "a":
            switchCode(code)

        default:
            literal("%")
            literal(code)
        }
    }

    /// The codes for a path or for names of a panel.
    private mutating func panelCode(_ code: Unicode.Scalar) {
        switch code {
        case "P", "p":
            insert(path: first.path)

        case "T", "t":
            insert(path: second.path)

        case "N", "n", "v":
            insert(name: requiring(first.cursorName) ?? "")

        case "V":
            insert(requiring(first.cursorName).map { first.path + $0 } ?? "")

        case "M", "m":
            insert(name: requiring(second.cursorName) ?? "")

        case "O", "o":
            insert(name: FileItem.split(requiring(first.cursorName) ?? "").base)

        case "E", "e":
            insert(FileItem.split(requiring(first.cursorName) ?? "").ext)

        case "S", "s":
            names(of: first)

        default:
            // `R`, `r`.
            names(of: second)
        }
    }

    /// The codes that put the name of a list file into the line.
    private mutating func listCode(_ code: Unicode.Scalar) {
        switch code {
        case "L", "l", "D":
            list(withPath: true, encoding: .plain)

        case "F", "f", "d":
            list(withPath: false, encoding: .plain)

        default:
            // `U` and `W` make a list only with an `L` or an `F` after them.
            guard let kind = next, kind == "L" || kind == "F" else {
                literal("%")
                literal(code)
                return
            }
            position += 1
            list(withPath: kind == "L", encoding: code == "U" ? .utf8WithMark : .utf16WithMark)
        }
    }

    /// The codes that change how the codes after them are read.
    private mutating func switchCode(_ code: Unicode.Scalar) {
        switch code {
        case "X":
            leftRight = true

        case "x":
            leftRight = false

        case "q":
            stripsQuotes.toggle()

        default:
            // `%Y`, `%y`, `%Q` and `%a` count for the whole text and were read in `init`; `%Z`
            // (archives) changes nothing.
            break
        }
    }
}
