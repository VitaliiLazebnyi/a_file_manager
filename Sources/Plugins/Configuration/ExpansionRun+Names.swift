import AFMKernel

/// `%S` and `%R`: the marked names of a panel, each its own word.
extension ExpansionRun {
    /// The affixes inside the user's quotes around the extension code (`before%Eafter`).
    private typealias Affixes = (before: [ExpandedPiece], after: [ExpandedPiece])

    /// The names `%S` and `%R` stand for (spec 18 › Empty-selection and archive modifiers):
    /// the marked ones, else the one under the cursor, unless `%Y` alone asks for none.
    internal func chosen(of panel: PanelSnapshot) -> [String] {
        if !panel.selection.isEmpty {
            return panel.selection
        }
        if emptyWhenUnselected, !dropsListWhenUnselected {
            return []
        }
        return panel.cursorName.map { [$0] } ?? []
    }

    /// `%S`, `%R`: every name is its own word.
    ///
    /// A path code directly in front goes before each name; inside the user's quotes each name
    /// gets its own pair, with the text around the code as affixes
    /// (`"before%Sbeforeext%Eafterext"`).
    internal mutating func names(of panel: PanelSnapshot) {
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
        let names = range(chosen(of: panel)).map(cut)
        guard isInsideDoubleQuotes, let quote = openQuote else {
            for (index, name) in names.enumerated() {
                if index > 0 { write(" ") }
                emit(value: prefix.isEmpty && lexer.isAtWordStart ? protected(name) : prefix + name)
            }
            return
        }
        quotedNames(names, prefix: prefix, quote: quote)
    }

    /// The names inside the user's quotes: the quote and what the user wrote after it come out of
    /// the line again and are written once for every name.
    private mutating func quotedNames(_ names: [String], prefix: String, quote: (pieces: Int, lexer: ShellContext)) {
        flushLiteral()
        var before = Array(pieces[quote.pieces...])
        pieces.removeSubrange(quote.pieces...)
        if case .text(let text)? = before.first { before[0] = .text(String(text.unicodeScalars.dropFirst())) }
        before = ParameterExpander.withoutEmptyTexts(before)
        lexer = quote.lexer
        openQuote = nil
        let protects = prefix.isEmpty && before.isEmpty && lexer.isAtWordStart
        let tail = quotedTail()
        let affixes = ParameterExpander.split(ParameterExpander.withoutEmptyTexts(tail), at: "%E")
        for (index, name) in names.enumerated() {
            if index > 0 { write(" ") }
            write("\"")
            for piece in before { emit(piece) }
            if let affixes {
                emit(name, prefix: prefix, protects: protects, around: affixes)
            } else {
                emit(value: protects ? protected(name) : prefix + name)
                for piece in tail { emit(piece) }
            }
            write("\"")
        }
    }

    /// One name with the affixes written around its extension.
    private mutating func emit(_ name: String, prefix: String, protects: Bool, around affixes: Affixes) {
        let parts = FileItem.split(name)
        emit(value: protects ? protected(parts.base) : prefix + parts.base)
        for piece in affixes.before { emit(piece) }
        if !parts.ext.isEmpty { emit(value: "." + parts.ext) }
        for piece in affixes.after { emit(piece) }
    }

    /// What the user wrote after the code up to the closing quote, which is read and dropped.
    private mutating func quotedTail() -> [ExpandedPiece] {
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
        return tail
    }
}
