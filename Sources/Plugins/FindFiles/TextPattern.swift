public import AFMKernel
public import Foundation

/// A text to look for inside files, prepared once and then used on many files at the same
/// time (spec 09 › "Find text").
///
/// **Threading.** A pattern is immutable; `isFound` may run on any number of threads at once,
/// each with its own reader. Files are read in blocks and never held in memory as a whole.
public struct TextPattern: Sendable {
    /// Why a text cannot be looked for.
    public enum Problem: LocalizedError, Equatable {
        /// The text is empty.
        case emptyText
        /// The text is to be hex bytes and is not.
        case badHex(String)
        /// The text is to be a regular expression and is not; the reason is the system's.
        case badRegex(String)
        /// None of the chosen encodings can write the text.
        case notRepresentable(String)

        /// The message shown for the problem.
        public var errorDescription: String? {
            switch self {
            case .emptyText:
                return "There is no text to find."

            case .badHex(let text):
                return "\"\(text)\" is not a string of hex bytes such as 00 FF 12 or \"PK\" 03 04."

            case .badRegex(let reason):
                return "The regular expression cannot be used: \(reason)"

            case .notRepresentable(let text):
                return "\"\(text)\" cannot be written in any of the chosen encodings."
            }
        }
    }

    private enum Matcher {
        case bytes([TextNeedle])
        case regex(NSRegularExpression, [TextEncoding])
    }

    /// A reader of bytes in memory, for looking for a text in data.
    ///
    /// Used by one thread at a time, as `FileReader` allows; `interrupt` (which does nothing)
    /// is the only call from another thread.
    internal final class DataReader: FileReader, @unchecked Sendable {
        private let data: Data
        private var position = 0

        /// A reader of `data`, from its start.
        internal init(_ data: Data) { self.data = data }

        /// Up to `count` bytes from where the reader stands; nil at the end.
        internal func read(upToCount count: Int) -> Data? {
            guard position < data.count else {
                return nil
            }
            let end = min(position + count, data.count)
            defer { position = end }
            return data.subdata(in: position..<end)
        }

        /// Moves the reader to `offset`, or to the end when the data is shorter.
        internal func seek(to offset: UInt64) { position = min(Int(clamping: offset), data.count) }

        /// Does nothing: the data stays until the reader goes.
        internal func close() {
            // Nothing to close.
        }

        deinit {
            // Nothing to release.
        }
    }

    /// What one piece of a file may take a regular expression.
    internal static let pieceBudget: TimeInterval = 2

    /// Counts the pieces of files a regular expression ran out of time on.
    internal let trip = RegexTrip()
    /// "NOT containing": a file passes when the text is not in it.
    public let notContaining: Bool
    /// The chosen encodings the text cannot be written in; they were left out.
    public let droppedEncodings: [TextEncoding]
    private let matcher: Matcher

    /// Prepares `text` for a search with `options`; without `caseSensitive`, upper and lower case are
    /// the same.
    ///
    /// Throws a `Problem` when the text cannot be looked for: it is empty, no hex string or regular
    /// expression where it is to be one, or written in none of the encodings.
    public init(_ text: String, caseSensitive: Bool = false, options: TextSearchOptions = TextSearchOptions()) throws {
        guard !text.isEmpty else {
            throw Problem.emptyText
        }
        notContaining = options.notContaining
        let encodings = options.encodings.isEmpty ? [TextEncoding.utf8] : options.encodings
        if options.hex {
            matcher = .bytes([
                TextNeedle(
                    elements: try Self.hexElements(text, caseSensitive: caseSensitive),
                    unit: 1,
                    bigEndian: false,
                    wholeWords: options.wholeWords
                )
            ])
            droppedEncodings = []
        } else if options.regex {
            do {
                let pattern = options.wholeWords ? "\\b(?:\(text))\\b" : text
                let regex = try NSRegularExpression(
                    pattern: pattern,
                    options: caseSensitive ? [.anchorsMatchLines] : [.anchorsMatchLines, .caseInsensitive]
                )
                matcher = .regex(regex, encodings)
                droppedEncodings = []
            } catch {
                throw Problem.badRegex(error.localizedDescription)
            }
        } else {
            let plain = Self.needles(
                for: Self.unescape(text),
                in: encodings,
                caseSensitive: caseSensitive,
                wholeWords: options.wholeWords
            )
            guard !plain.needles.isEmpty else {
                throw Problem.notRepresentable(text)
            }
            matcher = .bytes(plain.needles)
            droppedEncodings = plain.dropped
        }
    }

    // MARK: Searching

    /// Whether the file passes the text criterion: the text is in it, or, with "NOT
    /// containing", is not.
    ///
    /// A file that cannot be read never passes.
    public func accepts(_ reader: any FileReader, cancellation: CancellationFlag? = nil, blockSize: Int = 1 << 20)
        -> Bool
    {
        switch search(reader, cancellation: cancellation, blockSize: blockSize) {
        case .found:
            return !notContaining

        case .missing:
            return notContaining

        case .undecided:
            return false
        }
    }

    /// Whether the text occurs in the bytes the reader delivers.
    public func isFound(in reader: any FileReader, cancellation: CancellationFlag? = nil, blockSize: Int = 1 << 20)
        -> Bool
    {
        search(reader, cancellation: cancellation, blockSize: blockSize) == .found
    }

    /// Whether the text occurs in `data`, read in blocks of `blockSize` bytes as a file would be.
    public func isFound(in data: Data, blockSize: Int = 1 << 20) -> Bool {
        isFound(in: DataReader(data), blockSize: blockSize)
    }

    private func search(
        _ reader: any FileReader,
        cancellation: CancellationFlag?,
        blockSize: Int
    ) -> TextSearchOutcome {
        switch matcher {
        case .bytes(let needles):
            return TextNeedle.search(needles, reader, cancellation, blockSize)

        case .regex(let regex, let encodings):
            return TextRegexSearch(regex: regex, encodings: encodings, trip: trip, cancellation: cancellation)
                .run(reader, blockSize: blockSize)
        }
    }
}
