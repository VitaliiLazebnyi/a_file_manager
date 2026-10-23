public import Foundation

/// A text file as lines, with what is needed to write it back unchanged: its encoding and
/// every line's own line break.
///
/// A value; safe to hand between threads.
public struct TextDocument: Equatable, Sendable {
    /// The encoding the file was read in, and is written back in.
    public var encoding: TextEncoding
    /// The lines of the file, each with its own line break.
    public var lines: [TextLine]
    /// False when the bytes loaded were not valid in the encoding and were shown with replacement
    /// characters: saving would then change them, and is refused.
    public private(set) var isLossless = true

    /// The line break most lines use, counting all of them.
    public var usualEnding: LineEnding { usualEnding() }

    /// A document of `lines` in `encoding`.
    public init(encoding: TextEncoding = .utf8(bom: false), lines: [TextLine] = []) {
        self.encoding = encoding
        self.lines = lines
    }

    /// The document of a file's bytes, read in `encoding`, or in the encoding found for them when nil.
    public init(data: Data, encoding: TextEncoding? = nil) {
        if let encoding {
            self.encoding = encoding
            lines = Self.split(encoding.decode(data))
        } else {
            let found = TextEncoding.decodeDetectedChecked(data)
            self.encoding = found.encoding
            isLossless = found.isLossless
            lines = Self.split(found.text)
        }
    }

    /// Cuts a text at `\n`, `\r\n` and `\r`.
    ///
    /// A text that ends with a line break has no empty line after it.
    public static func split(_ text: String) -> [TextLine] {
        var found: [TextLine] = []
        var contiguous = text
        contiguous.withUTF8 { bytes in
            var start = 0
            var index = 0
            func line(to end: Int, _ ending: LineEnding) {
                found.append(
                    TextLine(
                        String(repairingUTF8: UnsafeBufferPointer(rebasing: bytes[start..<end])),
                        ending: ending,
                        number: found.count + 1
                    )
                )
            }
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x0A {
                    line(to: index, .lineFeed)
                    start = index + 1
                } else if byte == 0x0D {
                    let isPair = index + 1 < bytes.count && bytes[index + 1] == 0x0A
                    line(to: index, isPair ? .carriageReturnLineFeed : .carriageReturn)
                    if isPair {
                        index += 1
                    }
                    start = index + 1
                }
                index += 1
            }
            if start < bytes.count {
                line(to: bytes.count, .noBreak)
            }
        }
        return found
    }

    /// Files with a zero byte near the start are shown in hex; UTF-16 text is full of them
    /// and is recognised by its byte-order mark.
    public static func looksBinary(_ data: Data) -> Bool {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return false
        }
        return data.prefix(64 * 1_024).contains(0)
    }

    /// The line break most lines use; new lines get it, and so does a last line that had
    /// none when something is put after it. `sampleLimit` looks at that many lines at the start
    /// only (an edit in a huge file must not count them all).
    public func usualEnding(sampleLimit: Int = .max) -> LineEnding {
        var counts: [LineEnding: Int] = [:]
        for line in lines.prefix(sampleLimit) where line.ending != .noBreak {
            counts[line.ending, default: 0] += 1
        }
        return counts.max { first, second in first.value < second.value }?.key ?? .lineFeed
    }

    /// The whole text with its line breaks; a line without one that is not the last gets the usual one.
    private func text() -> String {
        let usual = usualEnding
        var text = ""
        for (index, line) in lines.enumerated() {
            text += line.text
            // Only the last line may go without a line break.
            text += line.ending == .noBreak && index < lines.count - 1 ? usual.rawValue : line.ending.rawValue
        }
        return text
    }

    /// The file's bytes: the same as were loaded as long as nothing was changed.
    public func data() -> Data {
        encoding.encode(text())
    }

    /// The file's bytes, or an error where they cannot be the text: characters the encoding cannot
    /// hold (they would become question marks), or a file that was not valid when loaded.
    internal func encodedData(named name: String) throws -> Data {
        guard isLossless else {
            throw CompareLoader.SaveError.invalidSequences(name, encoding)
        }
        guard let data = encoding.encodeExactly(text()) else {
            throw CompareLoader.SaveError.notRepresentable(name, encoding)
        }
        return data
    }
}
