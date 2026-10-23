import AFMKernel

/// Numbers, ranges and substrings after a code.
extension ExpansionRun {
    /// Positions `from`…`end` (1-based) of a list, counted from the start or from the end.
    internal static func slice<Element>(_ items: [Element], fromEnd: Bool, _ start: Int, _ end: Int?, open: Bool)
        -> [Element]
    {
        // The numbers are the user's and may be as large as an `Int`: nothing here may overflow.
        func fromTheEnd(_ index: Int) -> Int { index > items.count ? 0 : items.count - index + 1 }
        let from = fromEnd ? fromTheEnd(start) : start
        let upTo = open ? items.count : end.map { fromEnd ? fromTheEnd($0) : $0 } ?? from
        guard from >= 1, from <= min(upTo, items.count) else {
            return []
        }
        return Array(items[(from - 1)..<min(upTo, items.count)])
    }

    /// The part of `text` a substring suffix asks for.
    private static func cut(_ text: String, start: Int, fromEnd: Bool, length: Int?, lengthFromEnd: Bool) -> String {
        if fromEnd, start == 0 {
            // `-0` cuts the name without its extension, or the extension alone.
            let parts = FileItem.split(text)
            guard let length else {
                return parts.base
            }
            return String((lengthFromEnd ? parts.ext : parts.base).prefix(length))
        }
        let all = Array(text)
        let from = fromEnd ? max(0, all.count - min(start, all.count)) : min(start, all.count)
        var end = all.count
        if let length {
            // `from + length` with a length as large as an `Int` would overflow.
            end =
                lengthFromEnd
                ? all.count - min(length, all.count) : (length >= all.count - from ? all.count : from + length)
        }
        return from < end ? String(all[from..<end]) : ""
    }

    /// A number of any length: one too large to hold counts as the largest there is.
    internal mutating func number() -> Int? {
        var value: Int?
        while let character = next, character.value >= 48, character.value <= 57 {
            let digit = Int(character.value - 48)
            let (product, overflowed) = (value ?? 0).multipliedReportingOverflow(by: 10)
            let (sum, carried) = product.addingReportingOverflow(digit)
            value = overflowed || carried ? Int.max : sum
            position += 1
        }
        return value
    }

    /// `-<m>` or an open `-` after a position; restores the position when there is neither.
    internal mutating func rangeEnd(openWith openers: Set<Unicode.Scalar>) -> (end: Int?, open: Bool) {
        guard let character = next, openers.contains(character) else {
            return (nil, false)
        }
        position += 1
        if character == "-", let end = number() {
            return (end, false)
        }
        return (nil, true)
    }

    /// The forms after `%S`: `<n>`, `+<n>`, `+<n>-<m>`, `+<n>-`, `-<n>`, `-<n>-<m>`, `-<n>-`.
    internal mutating func selectionRange() -> ([String]) -> [String] {
        let start = position
        guard let sign = next, sign == "+" || sign == "-" else {
            guard let count = number() else {
                return \.self
            }
            return { Array($0.prefix(count)) }
        }
        position += 1
        guard let index = number() else {
            position = start
            return \.self
        }
        let (end, open) = rangeEnd(openWith: ["-"])
        return { Self.slice($0, fromEnd: sign == "-", index, end, open: open) }
    }

    /// The cmd.exe-style suffix `:~start,length` (spec 18 › Substrings).
    internal mutating func substring() -> (String) -> String {
        guard scalar(at: position) == ":", scalar(at: position + 1) == "~" else {
            return \.self
        }
        let begin = position
        position += 2
        let startIsNegative = next == "-"
        if startIsNegative { position += 1 }
        guard let start = number() else {
            position = begin
            return \.self
        }
        var length: Int?
        var lengthIsNegative = false
        if next == "," {
            let comma = position
            position += 1
            lengthIsNegative = next == "-"
            if lengthIsNegative { position += 1 }
            length = number()
            if length == nil { position = comma }
        }
        if length != nil, next == "~" { position += 1 }
        return { text in
            Self.cut(text, start: start, fromEnd: startIsNegative, length: length, lengthFromEnd: lengthIsNegative)
        }
    }
}
