import AFMKernel
import Foundation

/// The switches of the Find dialog (spec 10 › Find dialog); all off by default.
struct SearchOptions: Equatable, Codable {
    var wholeWords = false
    var caseSensitive = false
    var backwards = false
    var hex = false
    var regex = false
}

enum SearchError: LocalizedError, Equatable {
    case empty
    case badHex(String)
    case badExpression(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "There is nothing to search for."

        case .badHex(let text):
            return "\"\(text)\" is not a hex string. Write bytes as 00 FF 12, literal text in quotes: \"PK\"0102."

        case .badExpression(let reason):
            return "The regular expression cannot be used: \(reason)"
        }
    }
}

/// What the user typed into the Find dialog, made ready for searching (spec 10 › Pattern
/// rules).
///
/// An immutable value; safe to share between the searching threads.
struct SearchPattern {
    enum Kind {
        case bytes([UInt8])
        case text(String)
        case expression(NSRegularExpression)
    }

    let kind: Kind
    let wholeWords: Bool
    let caseSensitive: Bool

    /// `encoding` is the encoding the file is shown in; quoted text in a hex string is searched
    /// as its bytes in that encoding.
    init(_ text: String, options: SearchOptions, encoding: ViewerEncoding) throws {
        guard !text.isEmpty else { throw SearchError.empty }
        wholeWords = options.wholeWords && !options.hex
        caseSensitive = options.caseSensitive
        let insensitive: NSRegularExpression.Options = options.caseSensitive ? [] : [.caseInsensitive]
        func expression(_ pattern: String) throws -> Kind {
            do {
                return .expression(
                    try NSRegularExpression(pattern: pattern, options: insensitive.union(.anchorsMatchLines))
                )
            } catch {
                throw SearchError.badExpression(error.localizedDescription)
            }
        }
        if options.hex {
            kind = .bytes(try Self.hexBytes(text, encoding: encoding))
        } else if options.regex {
            kind = try expression(text)
        } else {
            // Not empty: unescaping turns every character into one or more.
            let plain = Self.unescape(text)
            // `\n` stands for a line break. The specification's Lister finds CR+LF only; files
            // on a Mac end their lines with LF, so every kind of line break is found.
            if plain.contains(Self.lineBreak) {
                let parts = plain.components(separatedBy: String(Self.lineBreak))
                    .map(
                        NSRegularExpression.escapedPattern(for:)
                    )
                kind = try expression(parts.joined(separator: "(?:\\r\\n|\\r|\\n)"))
            } else {
                kind = .text(plain)
            }
        }
    }

    /// Stands for `\n` between unescaping and building the search.
    private static let lineBreak: Character = "\u{E000}"

    /// `\t` is a tab, `\n` a line break, `\\` one backslash; any other backslash is itself.
    static func unescape(_ text: String) -> String {
        var result = ""
        var characters = text.makeIterator()
        while let character = characters.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            switch characters.next() {
            case "t":
                result.append("\t")

            case "n":
                result.append(lineBreak)

            case "\\":
                result.append("\\")

            case let other?:
                result.append("\\\(other)")

            case nil:
                result.append("\\")
            }
        }
        return result
    }

    /// `00 FF 12`, with or without spaces; text in double quotes stands for its bytes: `"PK"0102`.
    static func hexBytes(_ text: String, encoding: ViewerEncoding) throws -> [UInt8] {
        var bytes: [UInt8] = []
        var pending: UInt8?
        var characters = text.makeIterator()
        while let character = characters.next() {
            if character == "\"" {
                guard pending == nil else { throw SearchError.badHex(text) }
                var literal = ""
                var closed = false
                while let next = characters.next() {
                    if next == "\"" {
                        closed = true
                        break
                    }
                    literal.append(next)
                }
                guard closed, let encoded = encoding.encode(literal) else { throw SearchError.badHex(text) }
                bytes += encoded
            } else if let digit = character.hexDigitValue, character.isASCII {
                if let high = pending {
                    bytes.append(high << 4 | UInt8(digit))
                    pending = nil
                } else {
                    pending = UInt8(digit)
                }
            } else if character == " " || character == "," {
                guard pending == nil else { throw SearchError.badHex(text) }
            } else {
                throw SearchError.badHex(text)
            }
        }
        guard pending == nil, !bytes.isEmpty else { throw SearchError.badHex(text) }
        return bytes
    }
}

/// Searching a file of any size without loading it: the file is read in chunks that overlap by
/// more than a match is long, so a match across a chunk border is found in the earlier chunk.
///
/// Several chunks are read, decoded and searched at once on all cores; the first hit in file order
/// wins. Blocks; call it on a background thread.
enum ViewerSearch {
    /// The longest match a regular expression can have across a chunk border.
    static let expressionOverlap = 64 * 1_024

    /// The next match that begins at or after `start` or, with `backwards`, the last one that
    /// begins before `start`.
    ///
    /// Nil when there is none or the search was cancelled (a read that was blocked is interrupted).
    /// `progress` receives the share of the way that has been searched, on the calling thread.
    /// `boundaries` is what a text in a double-byte code page is cut into characters with; a search
    /// that is repeated keeps it between the calls. `rawBytes` off decodes every chunk (the
    /// reference the raw searches are tested against).
    static func find(
        _ pattern: SearchPattern,
        in source: any ByteSource,
        content: Range<Int64>,
        from start: Int64,
        backwards: Bool,
        encoding: ViewerEncoding,
        chunkSize: Int = 1 << 20,
        parallelism: Int = ProcessInfo.processInfo.activeProcessorCount,
        cancellation: CancellationFlag = CancellationFlag(),
        boundaries: CharacterBoundaries? = nil,
        rawBytes: Bool = true,
        progress: (Double) -> Void = { _ in }
    ) throws -> Range<Int64>? {
        let boundaries =
            encoding.kind == .doubleByte
            ? boundaries ?? CharacterBoundaries(source: source, content: content, encoding: encoding) : nil
        let context = Context(
            source: source,
            content: content,
            encoding: encoding,
            cancellation: cancellation,
            boundaries: boundaries,
            rawBytes: rawBytes
        )
        let unit = Int64(encoding.unitSize)
        let size = max(unit, Int64(chunkSize) / unit * unit)
        let start = min(max(start, content.lowerBound), content.upperBound)
        // Chunk borders stay on whole code units, counted from the start of the text.
        let origin =
            backwards ? start + (start - content.lowerBound) % unit : start - (start - content.lowerBound) % unit
        let total = backwards ? origin - content.lowerBound : content.upperBound - origin
        guard total > 0 else {
            return nil
        }
        let chunkCount = Int((total + size - 1) / size)
        var next = 0
        while next < chunkCount, !cancellation.isCancelled {
            let wave = Array(next..<min(chunkCount, next + max(1, parallelism)))
            let results: [Result<Range<Int64>?, any Error>] = Parallel.map(wave) { number in
                let owned: Range<Int64> =
                    backwards
                    ? max(content.lowerBound, origin - Int64(number + 1) * size)..<origin - Int64(number) * size
                    : origin + Int64(number) * size..<min(content.upperBound, origin + Int64(number + 1) * size)
                let accepted =
                    backwards
                    ? owned.lowerBound..<min(owned.upperBound, start) : max(owned.lowerBound, start)..<owned.upperBound
                // Each chunk frees what it read and decoded when it is done: the threads of the
                // pool live on, and a search of gigabytes would keep every buffer until they idle.
                return autoreleasepool { Result { try search(pattern, context, accepted: accepted, last: backwards) } }
            }
            for result in results {
                do {
                    if let match = try result.get() {
                        return match
                    }
                } catch {
                    // A read that the flag ended is no failure.
                    if cancellation.isCancelled {
                        return nil
                    }
                    throw error
                }
            }
            next += wave.count
            progress(min(1, Double(next) / Double(chunkCount)))
        }
        return nil
    }

    /// What a search of one chunk needs besides the pattern.
    private struct Context {
        let source: any ByteSource
        let content: Range<Int64>
        let encoding: ViewerEncoding
        let cancellation: CancellationFlag
        let boundaries: CharacterBoundaries?
        let rawBytes: Bool
    }

    /// The first (or last) match that begins inside `accepted`.
    ///
    /// Reads a little before it, for the character a whole word must not touch, and enough behind
    /// it for a match to end.
    private static func search(_ pattern: SearchPattern, _ context: Context, accepted: Range<Int64>, last: Bool) throws
        -> Range<Int64>?
    {
        let (source, content, encoding, cancellation) = (
            context.source, context.content, context.encoding, context.cancellation
        )
        switch pattern.kind {
        case .bytes(let needle):
            let lower = accepted.lowerBound
            let data = try source.read(
                lower..<min(content.upperBound, accepted.upperBound + Int64(needle.count - 1)),
                cancellation: cancellation
            )
            return bytes(needle, in: data, base: lower, accepted: accepted, last: last)

        case .text(let needle):
            // Matching case, the needle's bytes in a UTF-8 or one-byte-per-character file are
            // searched for in the raw bytes: no decoding, and no characters in between to go wrong.
            if pattern.caseSensitive, !pattern.wholeWords, encoding.kind == .utf8 || encoding.kind == .singleByte,
                let encoded = encoding.encode(needle), !encoded.isEmpty
            {
                let lower = accepted.lowerBound
                let data = try source.read(
                    lower..<min(content.upperBound, accepted.upperBound + Int64(encoded.count - 1)),
                    cancellation: cancellation
                )
                return bytes(encoded, in: data, base: lower, accepted: accepted, last: last)
            }
            // Letters of the other case and whole words need only the neighbours of an ASCII needle.
            if context.rawBytes, encoding.kind == .utf8 || encoding.kind == .singleByte,
                needle.utf8.allSatisfy({ $0 < 0x80 })
            {
                if case .answer(let found) = try rawASCII(
                    Array(needle.utf8),
                    pattern,
                    context,
                    accepted: accepted,
                    last: last
                ) {
                    return found
                }
            }
            let length = needle.utf16.count
            let matcher = TextMatcher(needle, caseSensitive: pattern.caseSensitive)
            // Folding can lengthen a match to several times the needle (ß for ss, ﬃ for ffi).
            return try decoded(context, accepted, Int64(max(4_096, length * 12 + 32))) { text, units, first, end in
                matcher.find(in: units, from: first, before: end, last: last) {
                    !pattern.wholeWords || isWholeWord($0, in: text)
                }
            }

        case .expression(let expression):
            return try decoded(context, accepted, Int64(expressionOverlap)) { text, _, first, end in
                var result: NSRange?
                // The text before `first` is context only (the 8 bytes decoded before `accepted`):
                // with the default options the range start would count as the start of the text,
                // and `^` and `\b` would match falsely there. `.reportProgress` lets a regular
                // expression that backtracks for ages be stopped.
                let options: NSRegularExpression.MatchingOptions = [
                    .withTransparentBounds, .withoutAnchoringBounds, .reportProgress
                ]
                expression.enumerateMatches(
                    in: text as String,
                    options: options,
                    range: NSRange(location: first, length: text.length - first)
                ) { match, _, stop in
                    if cancellation.isCancelled {
                        result = nil
                        stop.pointee = true
                        return
                    }
                    guard let match else {
                        return
                    }
                    if match.range.location >= end {
                        stop.pointee = true
                    } else if match.range.length > 0, !pattern.wholeWords || isWholeWord(match.range, in: text) {
                        result = match.range
                        if !last { stop.pointee = true }
                    }
                }
                return result
            }
        }
    }

    /// Decodes the surroundings of `accepted` and lets `match` look for a match that begins in
    /// the UTF-16 units `first..<end`, whose bytes are those of `accepted`; maps what it finds
    /// back to bytes.
    private static func decoded(
        _ context: Context,
        _ accepted: Range<Int64>,
        _ overlap: Int64,
        match: (_ text: NSString, _ units: [UInt16], _ first: Int, _ end: Int) -> NSRange?
    ) throws -> Range<Int64>? {
        let (source, content, encoding) = (context.source, context.content, context.encoding)
        var lower = max(content.lowerBound, accepted.lowerBound - 8)
        lower -= (lower - content.lowerBound) % Int64(encoding.unitSize)
        // A chunk border may fall on the second byte of a character of a double-byte text, and
        // the decoder would stay out of step with the characters from there. It starts at the
        // beginning of the character the border is in, which is found, not guessed.
        if let boundaries = context.boundaries, lower > content.lowerBound {
            lower = try boundaries.characterStart(atOrBefore: lower, cancellation: context.cancellation)
        }
        let upper = min(content.upperBound, accepted.upperBound + overlap)
        let data = try source.read(lower..<upper, cancellation: context.cancellation)
        var text = DecodedText()
        let used = encoding.decode(data, final: true, into: &text)
        func firstUnit(at offset: Int64) -> Int {
            var low = 0
            var high = text.offsets.count
            while low < high {
                let middle = (low + high) / 2
                if lower + Int64(text.offsets[middle]) < offset { low = middle + 1 } else { high = middle }
            }
            return low
        }
        guard !text.units.isEmpty else {
            return nil
        }
        let string = text.units.withUnsafeBufferPointer { NSString(characters: $0.baseAddress!, length: $0.count) }
        guard
            let found = match(
                string,
                text.units,
                firstUnit(at: accepted.lowerBound),
                firstUnit(at: accepted.upperBound)
            )
        else { return nil }
        let from = lower + Int64(text.offsets[found.location])
        let to =
            found.location + found.length < text.offsets.count
            ? lower + Int64(text.offsets[found.location + found.length]) : lower + Int64(used)
        return from..<to
    }

    // MARK: Text in decoded units

    /// Finds a text in decoded UTF-16 units, the same way whatever the chunk it is looked for
    /// in.
    ///
    /// Without case, both sides are folded a character at a time (ß and ss are the same, as are the
    /// ligatures and the Kelvin sign) and a match must begin and end at the border of a character
    /// of the text; nothing is skipped over, so a control character in the text is a character that
    /// does not match, as it is in the raw bytes.
    struct TextMatcher {
        private let needle: [UInt16]
        private let caseSensitive: Bool

        init(_ text: String, caseSensitive: Bool) {
            self.caseSensitive = caseSensitive
            let units = Array(text.utf16)
            if caseSensitive {
                needle = units
            } else {
                var cache: [UInt32: [UInt16]] = [:]
                var folded: [UInt16] = []
                var index = 0
                while index < units.count {
                    let (value, width) = Self.character(units, at: index)
                    if units[index] < 0x80 {
                        folded.append(units[index] >= 0x41 && units[index] <= 0x5A ? units[index] | 0x20 : units[index])
                    } else if let piece = Self.fold(value, &cache) {
                        folded.append(contentsOf: piece)
                    } else {
                        folded.append(contentsOf: units[index..<index + width])
                    }
                    index += width
                }
                needle = folded
            }
        }

        /// The scalar value at `index` and how many units it takes (a lone surrogate is its own value).
        @inline(__always)
        private static func character(_ units: [UInt16], at index: Int) -> (value: UInt32, width: Int) {
            let unit = units[index]
            if unit >= 0xD800, unit <= 0xDBFF, index + 1 < units.count, units[index + 1] >= 0xDC00,
                units[index + 1] <= 0xDFFF
            {
                return (0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(units[index + 1]) - 0xDC00), 2)
            }
            return (UInt32(unit), 1)
        }

        /// What a character folds to; nil when it folds to itself.
        private static func fold(_ value: UInt32, _ cache: inout [UInt32: [UInt16]]) -> [UInt16]? {
            guard let scalar = Unicode.Scalar(value), scalar.properties.changesWhenCaseFolded else {
                return nil
            }
            if let known = cache[value] {
                return known
            }
            let folded = Array(String(Character(scalar)).folding(options: [.caseInsensitive], locale: nil).utf16)
            cache[value] = folded
            return folded
        }

        /// Where the match of the needle that begins at `start` ends, if there is one: the folded
        /// characters from `start` on are exactly the needle, and its last character is whole.
        private func end(ofMatchAt start: Int, in units: [UInt16], _ cache: inout [UInt32: [UInt16]]) -> Int? {
            var matched = 0
            var index = start
            let count = units.count
            let length = needle.count
            while matched < length {
                guard index < count else {
                    return nil
                }
                let unit = units[index]
                if unit < 0x80 {
                    guard needle[matched] == (unit >= 0x41 && unit <= 0x5A ? unit | 0x20 : unit) else {
                        return nil
                    }
                    matched += 1
                    index += 1
                    continue
                }
                let (value, width) = Self.character(units, at: index)
                if let folded = Self.fold(value, &cache) {
                    guard matched + folded.count <= length else {
                        return nil
                    }
                    for offset in 0..<folded.count where needle[matched + offset] != folded[offset] { return nil }
                    matched += folded.count
                } else {
                    guard matched + width <= length, needle[matched] == unit,
                        width == 1 || needle[matched + 1] == units[index + 1]
                    else { return nil }
                    matched += width
                }
                index += width
            }
            return index
        }

        /// The first (or last) match that begins in the units `first..<end`, and ends in `units`
        /// (it may reach behind `end`) and for which `accepts` holds; units are indexes into `units`.
        func find(in units: [UInt16], from first: Int, before end: Int, last: Bool, accepts: (NSRange) -> Bool)
            -> NSRange?
        {
            guard !needle.isEmpty, first >= 0, first < end, first < units.count else {
                return nil
            }
            let end = min(end, units.count)
            if caseSensitive {
                let length = needle.count
                guard units.count >= length else {
                    return nil
                }
                var position = last ? min(end - 1, units.count - length) : first
                while last ? position >= first : position < end && position + length <= units.count {
                    if units[position] == needle[0], matches(units, at: position) {
                        let range = NSRange(location: position, length: length)
                        if accepts(range) {
                            return range
                        }
                    }
                    position += last ? -1 : 1
                }
                return nil
            }
            var cache: [UInt32: [UInt16]] = [:]
            let initial = needle[0]
            var index = last ? end - 1 : first
            while last ? index >= first : index < end {
                let unit = units[index]
                var width = 1
                if unit < 0x80 {
                    // Most characters are told apart by the first unit alone.
                    if (unit >= 0x41 && unit <= 0x5A ? unit | 0x20 : unit) == initial,
                        let stop = self.end(ofMatchAt: index, in: units, &cache)
                    {
                        let range = NSRange(location: index, length: stop - index)
                        if accepts(range) {
                            return range
                        }
                    }
                } else if last, unit >= 0xDC00, unit <= 0xDFFF, index > first, units[index - 1] >= 0xD800,
                    units[index - 1] <= 0xDBFF
                {
                    // The second half of a pair is no place for a match to begin.
                    index -= 1
                    continue
                } else {
                    width = Self.character(units, at: index).width
                    if let stop = self.end(ofMatchAt: index, in: units, &cache) {
                        let range = NSRange(location: index, length: stop - index)
                        if accepts(range) {
                            return range
                        }
                    }
                }
                index += last ? -1 : width
            }
            return nil
        }

        private func matches(_ units: [UInt16], at position: Int) -> Bool {
            for offset in 1..<max(1, needle.count) where units[position + offset] != needle[offset] { return false }
            return true
        }
    }

    // MARK: ASCII needles in the raw bytes

    private enum RawAnswer {
        /// A text with a character that matches case-insensitively without being ASCII: only
        /// decoding gives the answer the decoded search gives.
        case undecided
        case answer(Range<Int64>?)
    }

    /// The characters other than ASCII letters that a literal, case-insensitive search of
    /// `NSString` takes for ASCII letters: ß and ẞ for `ss`, the long s, the Kelvin sign,
    /// the ligatures ﬀ…ﬆ.
    ///
    /// A chunk that has one is left to the decoded search.
    private static let caseFolded: Set<UInt16> = [
        0xDF, 0x17F, 0x1E9E, 0x212A, 0xFB00, 0xFB01, 0xFB02, 0xFB03, 0xFB04, 0xFB05, 0xFB06
    ]

    /// Whether `data` has the UTF-8 form of one of `caseFolded`.
    private static func hasCaseFolded(utf8 data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            let count = raw.count
            guard count > 0, let start = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return false
            }
            var index = 0
            while index < count {
                if index + 8 <= count,
                    UnsafeRawPointer(start + index).loadUnaligned(as: UInt64.self) & 0x8080_8080_8080_8080 == 0
                {
                    index += 8
                    continue
                }
                let byte = start[index]
                if byte >= 0xC3, index + 1 < count {
                    let second = start[index + 1]
                    let third = index + 2 < count ? start[index + 2] : 0
                    switch byte {
                    case 0xC3 where second == 0x9F, 0xC5 where second == 0xBF:
                        return true

                    case 0xE1 where second == 0xBA && third == 0x9E, 0xE2 where second == 0x84 && third == 0xAA:
                        return true

                    case 0xEF where second == 0xAC && (0x80...0x86).contains(third):
                        return true

                    default:
                        break
                    }
                }
                index += 1
            }
            return false
        }
    }

    /// The first (or last) match of an ASCII `needle` that begins inside `accepted`, found in the
    /// raw bytes of a UTF-8 or one-byte-per-character text: a byte is compared with both cases
    /// of the letter, and for a whole word the characters on either side are looked at.
    ///
    /// The same answer as the decoded search gives; `undecided` where it could not be sure to.
    private static func rawASCII(
        _ needle: [UInt8],
        _ pattern: SearchPattern,
        _ context: Context,
        accepted: Range<Int64>,
        last: Bool
    ) throws -> RawAnswer {
        let (content, encoding) = (context.content, context.encoding)
        let isUTF8 = encoding.kind == .utf8
        // Four bytes either side are a character; a match is at most three bytes a letter long.
        let lower = max(content.lowerBound, accepted.lowerBound - 4)
        let upper = min(content.upperBound, accepted.upperBound + Int64(needle.count) * 3 + 4)
        let data = try context.source.read(lower..<upper, cancellation: context.cancellation)
        // The characters of the bytes of a text in a code page; nil for UTF-8.
        let table = isUTF8 ? nil : CodeTable.table(for: encoding)
        if let table {
            let folded = (0x80...0xFF).filter { caseFolded.contains(table.single[$0]) }.map(UInt8.init)
            let hasOne = data.withUnsafeBytes { raw in
                folded.contains { memchr(raw.baseAddress, Int32($0), raw.count) != nil }
            }
            if hasOne {
                return .undecided
            }
        } else if hasCaseFolded(utf8: data) {
            return .undecided
        }
        let folded = !pattern.caseSensitive
        let wanted = needle.map { folded && $0 >= 0x41 && $0 <= 0x5A ? $0 | 0x20 : $0 }
        let count = data.count
        var result: Range<Int64>?
        data.withUnsafeBytes { raw in
            guard count >= needle.count, let start = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            @inline(__always)
            func fold(_ byte: UInt8) -> UInt8 {
                folded && byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte
            }
            /// The classification of the character that ends at `end`, or begins at `begin`.
            func isWordUnit(_ unit: UInt16) -> Bool {
                guard let scalar = Unicode.Scalar(unit) else {
                    return false
                }
                return wordCharacters.contains(scalar)
            }
            func characterBefore(_ end: Int) -> Bool {
                guard end > 0 else {
                    return false
                }
                let byte = start[end - 1]
                // Beyond ASCII: by the table of the code page, or decoded as UTF-8.
                if byte >= 0x80 {
                    if let table {
                        return isWordUnit(table.single[Int(byte)])
                    }
                    var begin = end - 1
                    while begin > 0, end - begin < 4, start[begin] & 0xC0 == 0x80 { begin -= 1 }
                    var text = DecodedText()
                    text.tracksOffsets = false
                    _ = ViewerEncoding.utf8.decode(
                        UnsafeBufferPointer(start: start + begin, count: end - begin),
                        final: true,
                        into: &text
                    )
                    // Bytes decoded to the end give at least one unit.
                    return isWordUnit(text.units[text.units.count - 1])
                }
                return isWordUnit(UInt16(byte))
            }
            func characterAfter(_ begin: Int) -> Bool {
                guard begin < count else {
                    return false
                }
                let byte = start[begin]
                // Beyond ASCII: by the table of the code page, or decoded as UTF-8.
                if byte >= 0x80 {
                    if let table {
                        return isWordUnit(table.single[Int(byte)])
                    }
                    var text = DecodedText()
                    text.tracksOffsets = false
                    _ = ViewerEncoding.utf8.decode(
                        UnsafeBufferPointer(start: start + begin, count: min(4, count - begin)),
                        final: true,
                        into: &text
                    )
                    return isWordUnit(text.units[0])
                }
                return isWordUnit(UInt16(byte))
            }
            let first = wanted[0]
            let alternative: UInt8 = folded && first >= 0x61 && first <= 0x7A ? first & ~0x20 : first
            var position = Int(accepted.lowerBound - lower)
            let limit = Int(min(Int64(count), accepted.upperBound - lower))
            var nextLower = -1
            var nextUpper = -1
            func find(_ byte: UInt8, from: Int) -> Int {
                guard from < count, let found = memchr(start + from, Int32(byte), count - from) else {
                    return count
                }
                return start.distance(to: found.assumingMemoryBound(to: UInt8.self))
            }
            while position < limit, position + needle.count <= count {
                if nextLower < position { nextLower = find(first, from: position) }
                if alternative != first, nextUpper < position { nextUpper = find(alternative, from: position) }
                position = alternative != first ? min(nextLower, nextUpper) : nextLower
                guard position < limit, position + needle.count <= count else { break }
                var matches = true
                for offset in 1..<needle.count where fold(start[position + offset]) != wanted[offset] {
                    matches = false
                    break
                }
                if matches,
                    !pattern.wholeWords || !(characterBefore(position) || characterAfter(position + needle.count))
                {
                    result = lower + Int64(position)..<lower + Int64(position + needle.count)
                    if !last {
                        return
                    }
                }
                position += 1
            }
        }
        return .answer(result)
    }

    private static let wordCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))

    /// A whole word is not part of a longer one: `man` is not found in `manager`.
    private static func isWholeWord(_ range: NSRange, in text: NSString) -> Bool {
        func isWordCharacter(at index: Int) -> Bool {
            guard index >= 0, index < text.length, let scalar = Unicode.Scalar(text.character(at: index)) else {
                return false
            }
            return wordCharacters.contains(scalar)
        }
        return !isWordCharacter(at: range.location - 1) && !isWordCharacter(at: range.location + range.length)
    }

    /// The first (or last) place `needle` is in `data` at an offset inside `accepted`.
    static func bytes(_ needle: [UInt8], in data: Data, base: Int64, accepted: Range<Int64>, last: Bool) -> Range<
        Int64
    >? {
        data.withUnsafeBytes { (haystack: UnsafeRawBufferPointer) -> Range<Int64>? in
            guard !needle.isEmpty, haystack.count >= needle.count, let start = haystack.baseAddress else {
                return nil
            }
            var position = Int(max(0, accepted.lowerBound - base))
            var result: Range<Int64>?
            while position + needle.count <= haystack.count,
                let found = memmem(start + position, haystack.count - position, needle, needle.count)
            {
                let index = start.distance(to: UnsafeRawPointer(found))
                let offset = base + Int64(index)
                guard offset < accepted.upperBound else { break }
                result = offset..<offset + Int64(needle.count)
                if !last { break }
                position = index + 1
            }
            return result
        }
    }
}
