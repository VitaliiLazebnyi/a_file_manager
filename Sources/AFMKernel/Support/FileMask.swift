import Foundation

/// File masks for Select/Unselect group: `*.txt *.md`, `report_??.*` (spec 18 › File masks).
///
/// `*` stands for any run of characters and `?` for exactly one; every other character stands for itself, brackets and
/// backslashes included. Case does not count, and neither does the way an accent is written: a name with `é` in one
/// character and one with `e` and an accent after it match the same masks. (A character here is what Unicode numbers:
/// `é` is one, as is a picture; a letter with an accent that has no single form of its own is the letter and the
/// accent.)
///
/// A mask is read once, when it is made; matching a name then allocates nothing for the
/// usual names (ASCII), so a mask can be put to every entry of a long list. Matching takes
/// time in proportion to the length of the name times that of the mask at most, whatever
/// the two look like. A mask is a value that several threads can match with at once.
public struct FileMask: Sendable {
    /// How one mask is matched.
    ///
    /// The two shapes nearly every mask has, `*.txt` and `*text*`, need no pattern matcher at all.
    private enum Shape {
        /// `*` followed by plain text: the name ends with it.
        case suffix
        /// Plain text between two `*`: the name contains it.
        case infix
        /// Anything else: the text is the mask itself, `*` and `?` in it.
        case pattern
    }

    /// One mask, read.
    ///
    /// It points into memory that `Compiled` owns and holds no reference of its own: matching on many threads at once
    /// then counts no references, which would make the threads wait for one another on every name.
    private struct Matcher {
        let shape: Shape
        let text: UnsafeBufferPointer<UInt8>
        /// The mask in characters, for names of more than ASCII when the mask holds a `?`: one `?` is then one
        /// character, of however many bytes.
        ///
        /// Empty without a `?`.
        let characters: UnsafeBufferPointer<UInt32>

        /// True when a name of more than ASCII has to be matched character by character.
        var countsCharacters: Bool { !characters.isEmpty }

        /// A name given as bytes. `ignoringCase` is for a name that was not folded: its ASCII
        /// letters are then compared without regard to case (the masks are lowercase already).
        func matches(_ name: UnsafeBufferPointer<UInt8>, ignoringCase: Bool) -> Bool {
            @inline(__always)
            func byte(_ index: Int) -> UInt8 {
                let value = name[index]
                return ignoringCase && value >= 0x41 && value <= 0x5A ? value | 0x20 : value
            }
            func isEqual(_ start: Int) -> Bool {
                for offset in 0..<text.count where byte(start + offset) != text[offset] { return false }
                return true
            }
            switch shape {
            case .suffix:
                return name.count >= text.count && isEqual(name.count - text.count)

            case .infix:
                guard name.count >= text.count else {
                    return false
                }
                return (0...(name.count - text.count)).contains(where: isEqual)

            case .pattern:
                return FileMask.wild(
                    text.count,
                    name.count,
                    isAny: { text[$0] == 0x2A },
                    { token, index in text[token] == 0x3F || text[token] == byte(index) }
                )
            }
        }

        /// A folded name given as characters.
        func matches(_ name: UnsafeBufferPointer<UInt32>) -> Bool {
            FileMask.wild(
                characters.count,
                name.count,
                isAny: { characters[$0] == 0x2A },
                { token, index in characters[token] == 0x3F || characters[token] == name[index] }
            )
        }
    }

    /// The masks of one `FileMask`, read once and never changed: immutable after `init`, so
    /// several threads match with it at once.
    private final class Compiled: @unchecked Sendable {
        /// For each mask: the mask, and for one that ends with a dot the mask without it.
        let matchers: UnsafeBufferPointer<(whole: Matcher, withoutDot: Matcher?)>
        /// `*` or `*.*` is among the masks.
        let matchesAll: Bool
        /// A mask ends with a dot, so it matters whether a name has one.
        let asksForDot: Bool
        let countsCharacters: Bool
        private let memory: [UnsafeMutableRawBufferPointer]

        init(_ patterns: [String]) {
            var owned: [UnsafeMutableRawBufferPointer] = []
            func copy<Element>(_ elements: [Element]) -> UnsafeBufferPointer<Element> {
                guard !elements.isEmpty else {
                    return UnsafeBufferPointer(start: nil, count: 0)
                }
                let buffer = UnsafeMutableBufferPointer<Element>.allocate(capacity: elements.count)
                _ = buffer.initialize(from: elements)
                owned.append(UnsafeMutableRawBufferPointer(buffer))
                return UnsafeBufferPointer(buffer)
            }
            func matcher(_ pattern: String) -> Matcher {
                let bytes = Array(pattern.utf8)
                func isPlain(_ text: ArraySlice<UInt8>) -> Bool { !text.contains { $0 == 0x2A || $0 == 0x3F } }
                let characters = copy(bytes.contains(0x3F) ? pattern.unicodeScalars.map(\.value) : [])
                if bytes.count >= 2, bytes.first == 0x2A, bytes.last == 0x2A, isPlain(bytes[1..<(bytes.count - 1)]) {
                    let inner = copy(Array(bytes[1..<(bytes.count - 1)]))
                    return Matcher(shape: .infix, text: inner, characters: characters)
                }
                if bytes.first == 0x2A, isPlain(bytes.dropFirst()) {
                    return Matcher(shape: .suffix, text: copy(Array(bytes.dropFirst())), characters: characters)
                }
                return Matcher(shape: .pattern, text: copy(bytes), characters: characters)
            }
            matchesAll = patterns.contains { $0 == "*.*" || $0 == "*" }
            // `*.` and `name.` match names without an extension.
            let pairs = patterns.map { pattern in
                (
                    whole: matcher(pattern),
                    withoutDot: pattern.utf8.last == 0x2E
                        ? matcher(String(String.UnicodeScalarView(pattern.unicodeScalars.dropLast()))) : nil
                )
            }
            asksForDot = pairs.contains { $0.withoutDot != nil }
            countsCharacters = pairs.contains(where: \.whole.countsCharacters)
            matchers = copy(pairs)
            memory = owned
        }

        deinit {
            for buffer in memory { buffer.deallocate() }
        }
    }

    private let compiled: Compiled

    /// Several masks are separated by spaces or semicolons. `*.*` matches every name.
    public init(_ text: String) {
        let masks = Self.folded(text).unicodeScalars.split { $0 == " " || $0 == ";" }
        compiled = Compiled(masks.map { String(String.UnicodeScalarView($0)) })
    }

    /// The matching of `*` and `?`: `isAny` says whether a token of the mask is a `*`, and `fits(token, index)` whether
    /// another token takes the element of the name at `index`.
    ///
    /// One place to go back to is remembered, the last `*`, so the time is bounded by the two lengths multiplied.
    private static func wild(_ tokenCount: Int, _ nameCount: Int, isAny: (Int) -> Bool, _ fits: (Int, Int) -> Bool)
        -> Bool
    {
        var (token, index) = (0, 0)
        var (star, mark) = (-1, 0)
        while index < nameCount {
            if token < tokenCount, isAny(token) {
                (star, mark) = (token, index)
                token += 1
            } else if token < tokenCount, fits(token, index) {
                token += 1
                index += 1
            } else if star >= 0 {
                mark += 1
                (token, index) = (star + 1, mark)
            } else {
                return false
            }
        }
        // Only `*` may be left over.
        while token < tokenCount, isAny(token) { token += 1 }
        return token == tokenCount
    }

    /// The form masks and names are compared in: without case (`ß` like `ss`, as the rule for
    /// comparing without case has it) and with every accent written the composed way.
    private static func folded(_ text: String) -> String {
        text.folding(options: .caseInsensitive, locale: nil).precomposedStringWithCanonicalMapping
    }

    private static func matches(_ compiled: Compiled, _ name: UnsafeBufferPointer<UInt8>, ignoringCase: Bool) -> Bool {
        let hasDot = !compiled.asksForDot || name.contains(0x2E)
        for matcher in compiled.matchers
        where (hasDot ? matcher.whole : matcher.withoutDot ?? matcher.whole).matches(name, ignoringCase: ignoringCase) {
            return true
        }
        return false
    }

    /// Whether `name` (one name, not a path) matches one of the masks.
    ///
    /// Any thread.
    public func matches(_ name: String) -> Bool {
        let masks = compiled
        if masks.matchesAll {
            return true
        }
        if masks.matchers.isEmpty {
            return false
        }
        // An ASCII name is matched as it is, ignoring the case of its letters: that is what
        // folding it, like the masks, comes to.
        var name = name
        if let matched = name.withUTF8({ bytes in
            bytes.allSatisfy { $0 < 0x80 } ? Self.matches(masks, bytes, ignoringCase: true) : nil
        }) {
            return matched
        }
        // Any other name is folded first: case, and the way its accents are written.
        var folded = Self.folded(name)
        if !masks.countsCharacters || folded.utf8.allSatisfy({ $0 < 0x80 }) {
            return folded.withUTF8 { Self.matches(masks, $0, ignoringCase: false) }
        }
        // A `?` is one character, however many bytes it has.
        let characters = folded.unicodeScalars.map(\.value)
        return folded.withUTF8 { bytes in
            characters.withUnsafeBufferPointer { characters in
                let hasDot = bytes.contains(0x2E)
                return masks.matchers.contains { matcher in
                    let chosen = hasDot ? matcher.whole : matcher.withoutDot ?? matcher.whole
                    return chosen.countsCharacters
                        ? chosen.matches(characters) : chosen.matches(bytes, ignoringCase: false)
                }
            }
        }
    }
}
