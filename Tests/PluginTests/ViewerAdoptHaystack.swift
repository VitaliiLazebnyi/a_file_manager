import AFMKernel
import Foundation

@testable import ViewerPlugin

/// A text the search tests look through: its bytes and their encoding, how many bytes the search reads at a time,
/// and the character starts it may know already.
internal struct ViewerAdoptHaystack {
    /// The bytes of the text.
    internal let data: Data
    /// The encoding of the bytes.
    internal let encoding: ViewerEncoding
    /// The bytes the search reads at a time.
    internal let chunk: Int
    /// The character starts of a double-byte text, or nil for the search to find them itself.
    internal let boundaries: CharacterBoundaries?

    /// Every place `needle` is in `data` when all of it is decoded at once: the reference the search must agree with.
    internal static func occurrences(
        of needle: String,
        in data: Data,
        encoding: ViewerEncoding,
        caseSensitive: Bool,
        wholeWords: Bool
    ) -> [Range<Int64>] {
        var text = DecodedText()
        let used = encoding.decode(data, final: true, into: &text)
        // A unit that is no character becomes one replacement character, so the offsets stay those of the units.
        let string = text.string
        let units = text.units
        let word = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        func isWord(_ index: Int) -> Bool {
            guard index >= 0, index < units.count, let scalar = Unicode.Scalar(units[index]) else {
                return false
            }
            return word.contains(scalar)
        }
        var found: [Range<Int64>] = []
        var from = 0
        let length = needle.utf16.count
        let options: String.CompareOptions = caseSensitive ? [.literal] : [.literal, .caseInsensitive]
        while from + length <= units.count {
            let lower = String.Index(utf16Offset: from, in: string)
            guard let match = string.range(of: needle, options: options, range: lower..<string.endIndex) else {
                break
            }
            let location = match.lowerBound.utf16Offset(in: string)
            let end = match.upperBound.utf16Offset(in: string)
            from = location + 1
            if wholeWords, isWord(location - 1) || isWord(end) { continue }
            found.append(
                Int64(text.offsets[location])..<(end < text.offsets.count ? Int64(text.offsets[end]) : Int64(used))
            )
        }
        return found
    }

    /// The first place the viewer's search finds `needle` from `start` on (or before it, backwards), reading the raw
    /// bytes where it can (`raw`) or decoding everything.
    internal func find(
        _ needle: String,
        _ options: SearchOptions,
        from start: Int64,
        raw: Bool
    ) throws -> Range<Int64>? {
        let pattern = try SearchPattern(needle, options: options, encoding: encoding)
        return try ViewerSearch.find(
            ViewerSearch.Request(pattern: pattern, start: start, backwards: options.backwards),
            in: ViewerSearch.Subject(
                source: DataByteSource(data),
                content: 0..<Int64(data.count),
                encoding: encoding,
                boundaries: boundaries
            ),
            tuning: ViewerSearch.Tuning(
                chunkSize: chunk,
                parallelism: 3,
                rawBytes: raw
            ),
            cancellation: CancellationFlag()
        ) { _ in
            // Not watched here.
        }
    }
}
