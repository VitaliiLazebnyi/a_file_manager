/// Writing the expanded line: the user's characters, the values, and the word values gather in.
extension ExpansionRun {
    /// A character the user wrote.
    internal mutating func literal(_ character: Unicode.Scalar) {
        flushWord()
        let wasInside = isInsideDoubleQuotes
        var opened: (pieces: Int, lexer: ShellContext)?
        if character == "\"", !wasInside {
            flushLiteral()
            opened = (pieces.count, lexer)
        }
        write(character)
        guard character == "\"" else {
            return
        }
        if !wasInside, isInsideDoubleQuotes {
            openQuote = opened
        } else if wasInside, !isInsideDoubleQuotes {
            openQuote = nil
        }
    }

    /// Writes a character into the line and has the lexer follow it.
    internal mutating func write(_ character: Unicode.Scalar) {
        literal.append(character)
        lexer.feed(character)
    }

    /// Writes a text into the line and has the lexer follow it.
    internal mutating func write(_ text: String) {
        for scalar in text.unicodeScalars { write(scalar) }
    }

    /// Ends the text written since the last value as a piece of its own.
    internal mutating func flushLiteral() {
        guard !literal.isEmpty else {
            return
        }
        pieces.append(.text(String(literal)))
        literal = String.UnicodeScalarView()
    }

    /// Data goes out as a value; with `%Q` it is pasted into the line as it is.
    internal mutating func emit(value: String) {
        flushLiteral()
        if quotesAutomatically {
            pieces.append(.value(value))
            lexer.feedValue()
        } else {
            pieces.append(.raw(value))
            lexer.feed(value)
        }
    }

    /// Passes on a piece of an earlier expansion or of the user's arguments as the kind it is.
    internal mutating func emit(_ piece: ExpandedPiece) {
        switch piece {
        case .text(let text):
            write(text)

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
    internal mutating func requiring(_ name: String?) -> String? {
        if name == nil { missingName = true }
        return name
    }

    /// A name that begins with `-` would be read as an option: `./` in front says it is a file.
    internal func protected(_ name: String) -> String {
        name.unicodeScalars.first == "-" && quotesAutomatically ? "./" + name : name
    }

    /// Adds the value of a code to the word being gathered, cut by a substring suffix after it.
    internal mutating func insert(_ value: String) {
        gather(value, isPath: false, isName: false)
    }

    /// The same for a path, which a following `%S` puts in front of every name.
    internal mutating func insert(path: String) {
        gather(path, isPath: true, isName: false)
    }

    /// The same for a file name, which is protected when it begins a word of the line.
    internal mutating func insert(name: String) {
        gather(name, isPath: false, isName: true)
    }

    /// Ends the word gathered from codes as one value.
    internal mutating func flushWord() {
        guard let value = word else {
            return
        }
        word = nil
        wordIsPath = false
        emit(value: value)
    }

    /// Adds `value` to the word, with the substring suffix that follows the code applied.
    private mutating func gather(_ value: String, isPath: Bool, isName: Bool) {
        var text = substring()(value)
        // Only at the start of a word of the line: after a blank inside the user's quotes
        // the name is no argument of its own.
        if isName, word == nil, lexer.isAtWordStart { text = protected(text) }
        wordIsPath = word == nil && isPath
        word = (word ?? "") + text
    }
}
