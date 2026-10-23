/// A part of a text by character positions (spec 18 › Range forms): `2-5`, `2,5`, `-8-5`, `02-9`.
internal struct CharacterRange: Equatable {
    /// Where the part ends.
    internal enum End: Equatable {
        /// One character.
        case single
        /// To the end of the text.
        case toEnd
        /// Up to this position; negative counts from the end.
        case position(Int)
        /// This many characters.
        case length(Int)
    }

    /// `0` or a space: the result is left-filled to the width the range asks for.
    internal var pad: Character?
    /// 1 is the first character, -1 the last.
    internal var first: Int
    /// Where the part ends.
    internal var end: End

    /// The part of `text`, filled to its width with `pad`.
    internal func apply(to text: String) -> String {
        let characters = Array(text)
        let count = characters.count
        func index(_ position: Int) -> Int { position < 0 ? count + position : position - 1 }
        let start = index(first)
        var last: Int
        var width: Int?
        switch end {
        case .single:
            last = start
            width = 1

        case .toEnd:
            last = count - 1

        case .position(let position):
            // After a start counted from the end, the end is counted from the end as well:
            // `[N-8-5]` is the 8th-last to the 5th-last character.
            let counted = first < 0 && position > 0 ? -position : position
            last = index(counted)
            if (first < 0) == (counted < 0) {
                width = abs(counted - first) + 1
            }

        case .length(let length):
            last = start + length - 1
            width = length
        }
        let from = max(start, 0)
        last = min(last, count - 1)
        var result = from <= last ? String(characters[from...last]) : ""
        // No name is longer than 255 characters, so a wider fill is never wanted.
        if let pad, let filled = width.map({ min($0, RenameMask.widestFill) }), result.count < filled {
            result = String(repeating: pad, count: filled - result.count) + result
        }
        return result
    }
}
