import AFMKernel
import Foundation
import FuzzCore

@testable import ViewerPlugin

/// What one input of the `search` target asks for: the encoding, the options, the pattern, where the search
/// starts, and the bytes searched.
internal struct SearchInput {
    /// The expressions tried: the user's own are not, so that the time spent is the search's.
    internal static let safeExpressions = [
        "a+", "\\bfoo", "^x", "o$", "[0-9]+", "(?i)bar", "\\w+\\s", ".", "\\r\\n", "(a|b)c", "\\x{3042}", "x{2,3}",
        "\\Bb", "é", "[^\\x00-\\x7F]"
    ]

    /// The encoding of the text.
    internal let encoding: ViewerEncoding
    /// The search options.
    internal let options: SearchOptions
    /// The chunk size of the search.
    internal let chunk: Int
    /// How many threads search.
    internal let parallelism: Int
    /// The pattern as typed.
    internal let typed: String
    /// The pattern.
    internal let pattern: SearchPattern
    /// The file's bytes.
    internal let data: [UInt8]
    /// The file.
    internal let source: DataByteSource
    /// The part of the file searched: all but a byte order mark.
    internal let content: Range<Int64>
    /// Where the search starts; one before the file and one past it are tried too.
    internal let start: Int64
    /// The character boundaries the raw search shares, for a double-byte encoding.
    internal let shared: CharacterBoundaries?
    /// The input in words, for the detail of a finding.
    internal let what: String

    /// The input read out of `bytes`; nil when the pattern is not one.
    @MainActor
    internal init?(_ bytes: [UInt8]) {
        var choices = Choices(bytes)
        encoding = kEncodings[choices.int(kEncodings.count)]
        let flags = choices.byte()
        options = Self.searchOptions(flags)
        chunk = size(&choices)
        let startChoice = Int(choices.u16())
        parallelism = 1 + choices.int(4)
        let patternBytes = choices.until(0)
        data = choices.rest()
        typed = Self.typedPattern(patternBytes, options: options)
        guard let made = try? SearchPattern(typed, options: options, encoding: encoding) else {
            return nil
        }
        pattern = made
        source = DataByteSource(Data(data))
        let bom = Int64(min(data.count, Int(flags >> 6)))
        content = bom..<Int64(data.count)
        start = Int64(startChoice % (data.count + 2)) - 1
        what =
            "cp \(encoding.codePage) pattern \(typed.debugDescription) \(options) chunk \(chunk) start \(start) "
            + "content \(content) parallelism \(parallelism)"
        shared =
            encoding.kind == .doubleByte
            ? CharacterBoundaries(source: source, content: content, encoding: encoding, spacing: 16 + chunk % 64)
            : nil
    }

    /// The options the low five bits of `flags` turn on.
    private static func searchOptions(_ flags: UInt8) -> SearchOptions {
        var chosen = SearchOptions()
        chosen.caseSensitive = flags & 1 != 0
        chosen.wholeWords = flags & 2 != 0
        chosen.backwards = flags & 4 != 0
        chosen.hex = flags & 8 != 0
        chosen.regex = flags & 16 != 0
        return chosen
    }

    /// The pattern typed: the bytes as text, or one of the safe expressions for a regular expression.
    private static func typedPattern(_ bytes: [UInt8], options: SearchOptions) -> String {
        if options.regex, !options.hex {
            return safeExpressions[bytes.reduce(0) { $0 &+ Int($1) } % safeExpressions.count]
        }
        return fzText(bytes.prefix(48))
    }

    /// The match from `from`; nil when the search threw, `.some(nil)` when it found nothing.
    internal func find(_ chunkSize: Int, raw: Bool, shared boundaries: CharacterBoundaries?, from: Int64)
        -> Range<Int64>??
    {
        do {
            return .some(
                try ViewerSearch.find(
                    ViewerSearch.Request(pattern: pattern, start: from, backwards: options.backwards),
                    in: ViewerSearch.Subject(
                        source: source,
                        content: content,
                        encoding: encoding,
                        boundaries: boundaries
                    ),
                    tuning: ViewerSearch.Tuning(chunkSize: chunkSize, parallelism: parallelism, rawBytes: raw),
                    cancellation: CancellationFlag()
                ) { _ in
                    // No progress is wanted.
                }
            )
        } catch {
            return nil
        }
    }
}
