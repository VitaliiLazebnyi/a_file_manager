/// A cursor over the inside of one pair of brackets of a rename mask.
internal struct RenameMaskScanner {
    /// The characters between the brackets.
    internal let characters: [Character]
    /// Where the cursor is.
    internal var position = 0

    /// Whether a character range (`2-5`, ` 3`, `02,4`) starts here.
    internal var startsRange: Bool {
        startsPosition(0) || (peek(0) == " " && startsPosition(1))
    }

    /// The characters `characters`, the cursor on the first.
    internal init(characters: [Character]) {
        self.characters = characters
    }

    /// The character `offset` places after the cursor; nil beyond the end.
    internal func peek(_ offset: Int) -> Character? {
        characters.indices.contains(position + offset) ? characters[position + offset] : nil
    }

    /// The character at the cursor, which moves on; nil at the end.
    internal mutating func next() -> Character? {
        guard let character = peek(0) else {
            return nil
        }
        position += 1
        return character
    }

    /// Moves on over `character` if it is at the cursor; whether it was.
    internal mutating func accept(_ character: Character) -> Bool {
        guard peek(0) == character else {
            return false
        }
        position += 1
        return true
    }

    /// Whether the character `offset` places after the cursor is an ASCII digit.
    internal func isDigit(_ offset: Int) -> Bool { peek(offset).map { $0.isASCII && $0.isNumber } ?? false }

    /// The number at the cursor, at most nine digits; nil when there is none.
    internal mutating func number() -> Int? {
        var digits = ""
        while isDigit(0), digits.count < 9, let digit = next() {
            digits.append(digit)
        }
        return Int(digits)
    }

    /// `-5` as well as `5`; nil, and the cursor where it was, for anything else or 0.
    internal mutating func signedPosition() -> Int? {
        let start = position
        let negative = accept("-")
        guard let value = number(), value > 0 else {
            position = start
            return nil
        }
        return negative ? -value : value
    }

    /// Whether a position (`5`, `-5`) starts `offset` places after the cursor.
    internal func startsPosition(_ offset: Int) -> Bool {
        isDigit(offset) || (peek(offset) == "-" && isDigit(offset + 1))
    }

    /// The character range at the cursor; nil, and the cursor where it was, when there is none.
    internal mutating func range() -> CharacterRange? {
        let start = position
        var pad: Character?
        if peek(0) == "0" || peek(0) == " ", startsPosition(1) {
            pad = next()
        }
        guard let first = signedPosition() else {
            position = start
            return nil
        }
        if accept(",") {
            guard let length = number() else {
                position = start
                return nil
            }
            return CharacterRange(pad: pad, first: first, end: .length(length))
        }
        if accept("-") {
            if let last = signedPosition() {
                return CharacterRange(pad: pad, first: first, end: .position(last))
            }
            return CharacterRange(pad: pad, first: first, end: .toEnd)
        }
        return CharacterRange(pad: pad, first: first, end: .single)
    }
}
