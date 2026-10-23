import AFMKernel
import Foundation

/// Searching a file of any size without loading it: the file is read in chunks that overlap by
/// more than a match is long, so a match across a chunk border is found in the earlier chunk.
///
/// Several chunks are read, decoded and searched at once on all cores; the first hit in file order
/// wins. Blocks; call it on a background thread.
internal enum ViewerSearch {
    /// The longest match a regular expression can have across a chunk border.
    internal static let expressionOverlap = 64 * 1_024

    /// The characters a whole word is made of.
    internal static let wordCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))

    /// The match `request` asks for.
    ///
    /// Nil when there is none or the search was cancelled (a read that was blocked is interrupted).
    /// `progress` receives the share of the way that has been searched, on the calling thread.
    internal static func find(
        _ request: Request,
        in subject: Subject,
        tuning: Tuning,
        cancellation: CancellationFlag,
        progress: (Double) -> Void
    ) throws -> Range<Int64>? {
        let (content, encoding) = (subject.content, subject.encoding)
        let context = Self.context(subject, tuning, cancellation)
        let backwards = request.backwards
        let unit = Int64(encoding.unitSize)
        let size = max(unit, Int64(tuning.chunkSize) / unit * unit)
        let start = min(max(request.start, content.lowerBound), content.upperBound)
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
            let wave = Array(next..<min(chunkCount, next + max(1, tuning.parallelism)))
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
                return autoreleasepool {
                    Result { try search(request.pattern, context, accepted: accepted, last: backwards) }
                }
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

    /// What the searches of the chunks of `subject` share.
    private static func context(_ subject: Subject, _ tuning: Tuning, _ cancellation: CancellationFlag) -> Context {
        let boundaries =
            subject.encoding.kind == .doubleByte
            ? subject.boundaries
                ?? CharacterBoundaries(
                    source: subject.source,
                    content: subject.content,
                    encoding: subject.encoding,
                    spacing: CharacterBoundaries.standardSpacing
                )
            : nil
        return Context(
            source: subject.source,
            content: subject.content,
            encoding: subject.encoding,
            cancellation: cancellation,
            boundaries: boundaries,
            rawBytes: tuning.rawBytes
        )
    }

    /// The first (or last) place `needle` is in `data` at an offset inside `accepted`.
    internal static func bytes(_ needle: [UInt8], in data: Data, base: Int64, accepted: Range<Int64>, last: Bool)
        -> Range<Int64>?
    {
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

    /// The first (or last) match that begins inside `accepted`.
    ///
    /// Reads a little before it, for the character a whole word must not touch, and enough behind
    /// it for a match to end.
    private static func search(_ pattern: SearchPattern, _ context: Context, accepted: Range<Int64>, last: Bool) throws
        -> Range<Int64>?
    {
        switch pattern.kind {
        case .bytes(let needle):
            return try searchBytes(needle, context, accepted: accepted, last: last)

        case .text(let needle):
            return try searchText(needle, pattern, context, accepted: accepted, last: last)

        case .expression(let expression):
            return try searchExpression(expression, pattern, context, accepted: accepted, last: last)
        }
    }

    /// `bytes` in what is read of `accepted` and the bytes a match may reach behind it.
    private static func searchBytes(_ needle: [UInt8], _ context: Context, accepted: Range<Int64>, last: Bool) throws
        -> Range<Int64>?
    {
        let lower = accepted.lowerBound
        let data = try context.source.read(
            lower..<min(context.content.upperBound, accepted.upperBound + Int64(needle.count - 1)),
            cancellation: context.cancellation
        )
        return bytes(needle, in: data, base: lower, accepted: accepted, last: last)
    }

    /// A text: in the raw bytes where that gives the same answer, else in the decoded text.
    private static func searchText(
        _ needle: String,
        _ pattern: SearchPattern,
        _ context: Context,
        accepted: Range<Int64>,
        last: Bool
    ) throws -> Range<Int64>? {
        let encoding = context.encoding
        // Matching case, the needle's bytes in a UTF-8 or one-byte-per-character file are
        // searched for in the raw bytes: no decoding, and no characters in between to go wrong.
        if pattern.caseSensitive, !pattern.wholeWords, encoding.kind == .utf8 || encoding.kind == .singleByte,
            let encoded = try? encoding.encode(needle), !encoded.isEmpty
        {
            return try searchBytes(encoded, context, accepted: accepted, last: last)
        }
        // Letters of the other case and whole words need only the neighbours of an ASCII needle.
        if context.rawBytes, encoding.kind == .utf8 || encoding.kind == .singleByte,
            needle.utf8.allSatisfy({ $0 < 0x80 }),
            case .answer(let found) = try rawASCII(Array(needle.utf8), pattern, context, accepted: accepted, last: last)
        {
            return found
        }
        let length = needle.utf16.count
        let matcher = TextMatcher(needle, caseSensitive: pattern.caseSensitive)
        // Folding can lengthen a match to several times the needle (ß for ss, ﬃ for ffi).
        return try decoded(context, accepted, Int64(max(4_096, length * 12 + 32))) { units, first, end in
            matcher.find(in: units, from: first, before: end, last: last) { range in
                !pattern.wholeWords || isWholeWord(range, in: units)
            }
        }
    }

    /// A regular expression, in the decoded text.
    private static func searchExpression(
        _ expression: NSRegularExpression,
        _ pattern: SearchPattern,
        _ context: Context,
        accepted: Range<Int64>,
        last: Bool
    ) throws -> Range<Int64>? {
        let cancellation = context.cancellation
        return try decoded(context, accepted, Int64(expressionOverlap)) { units, first, end in
            var result: NSRange?
            // The text before `first` is context only (the 8 bytes decoded before `accepted`):
            // with the default options the range start would count as the start of the text,
            // and `^` and `\b` would match falsely there. `.reportProgress` lets a regular
            // expression that backtracks for ages be stopped.
            let options: NSRegularExpression.MatchingOptions = [
                .withTransparentBounds, .withoutAnchoringBounds, .reportProgress
            ]
            expression.enumerateMatches(
                in: String(utf16CodeUnits: units, count: units.count),
                options: options,
                range: NSRange(location: first, length: units.count - first)
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
                } else if match.range.length > 0, !pattern.wholeWords || isWholeWord(match.range, in: units) {
                    result = match.range
                    if !last { stop.pointee = true }
                }
            }
            return result
        }
    }

    /// Decodes the surroundings of `accepted` and lets `match` look for a match that begins in
    /// the UTF-16 units `first..<end`, whose bytes are those of `accepted`; maps what it finds
    /// back to bytes.
    private static func decoded(
        _ context: Context,
        _ accepted: Range<Int64>,
        _ overlap: Int64,
        match: (_ units: [UInt16], _ first: Int, _ end: Int) -> NSRange?
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
        guard !text.units.isEmpty,
            let found = match(text.units, firstUnit(at: accepted.lowerBound), firstUnit(at: accepted.upperBound))
        else { return nil }
        let lowerOffset = lower + Int64(text.offsets[found.location])
        let upperOffset =
            found.location + found.length < text.offsets.count
            ? lower + Int64(text.offsets[found.location + found.length]) : lower + Int64(used)
        return lowerOffset..<upperOffset
    }

    /// A whole word is not part of a longer one: `man` is not found in `manager`.
    private static func isWholeWord(_ range: NSRange, in units: [UInt16]) -> Bool {
        func isWordCharacter(at index: Int) -> Bool {
            guard index >= 0, index < units.count, let scalar = Unicode.Scalar(units[index]) else {
                return false
            }
            return wordCharacters.contains(scalar)
        }
        return !isWordCharacter(at: range.location - 1) && !isWordCharacter(at: range.location + range.length)
    }
}
