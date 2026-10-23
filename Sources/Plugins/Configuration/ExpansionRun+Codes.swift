/// The codes for a variable, a directory name, the compared files and the typed arguments.
extension ExpansionRun {
    /// `%|NAME|`: the value of an environment variable; empty for one that is not set.
    internal mutating func environmentVariable() {
        var name = String.UnicodeScalarView()
        while let character = next {
            position += 1
            if character == "|" { break }
            name.append(character)
        }
        flushWord()
        emit(value: stripped(context.environment[String(name)] ?? ""))
    }

    /// `%B` and its forms: one directory name of the source or target path.
    internal mutating func directoryName() {
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
        // (Cut at the `/` scalars, as a shell cuts at the `/` bytes: a name may begin with a
        // combining mark, which a cut by characters would glue to the `/`.)
        let parts = panel.path.unicodeScalars.split(separator: "/").map { String(String.UnicodeScalarView($0)) }
        if fromStart {
            // The Mac has no drive letters: `%B+` is the root, `%B+0` is empty.
            guard let index else {
                insert("/")
                return
            }
            insert(index >= 1 && index <= parts.count ? parts[index - 1] : "")
        } else {
            let back = index ?? 0
            insert(back < parts.count ? parts[parts.count - 1 - back] : "")
        }
    }

    /// `%C1` … `%C9`: the files Compare by Content would take, with their paths.
    internal mutating func comparedFile(_ code: Unicode.Scalar) {
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
        guard number <= 2 else {
            insert(selected.count >= number ? source.path + selected[number - 1] : "")
            return
        }
        let firstName = selected.first ?? source.cursorName
        var one = firstName.map { source.path + $0 } ?? ""
        var two =
            selected.count >= 2
            ? source.path + selected[1]
            : (target.selection.first ?? firstName).map { target.path + $0 } ?? ""
        if context.sourceIsRight, selected.count < 2 { swap(&one, &two) }
        insert(number == 1 ? one : two)
    }

    /// `%A` and its forms: the words typed after the command's name (spec 18 › Alias-only codes).
    internal mutating func arguments() {
        usedArguments = true
        flushWord()
        let typed: [ExpandedPiece] =
            context.argumentPieces.isEmpty ? [.text(context.arguments)] : context.argumentPieces
        let start = position
        let fromEnd = next == "-"
        if fromEnd { position += 1 }
        guard let index = number() else {
            position = start
            for piece in typed { emit(stripped(piece)) }
            return
        }
        let (end, open) = rangeEnd(openWith: ["-", "+"])
        let words = Self.slice(ShellWords.split(typed), fromEnd: fromEnd, index, end, open: open)
        for (wordIndex, typedWord) in words.enumerated() {
            if wordIndex > 0 { write(" ") }
            for piece in typedWord { emit(stripped(piece)) }
        }
    }

    /// `%q` takes the double quotes out of what the user typed.
    internal func stripped(_ text: String) -> String {
        stripsQuotes ? String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != "\"" })) : text
    }

    /// The same for a piece: a value has no quotes of its own.
    internal func stripped(_ piece: ExpandedPiece) -> ExpandedPiece {
        if case .text(let text) = piece {
            return .text(stripped(text))
        }
        return piece
    }
}
