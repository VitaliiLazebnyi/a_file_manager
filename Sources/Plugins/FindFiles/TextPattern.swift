public import AFMKernel
public import Foundation

/// The encodings "Find text" can look for a text in (spec 09 › "Find text"). The Windows
/// pair "ANSI" and "ASCII (DOS)" is kept for files that come from there; UTF-8 is what a Mac
/// writes and therefore the default.
public enum TextEncoding: String, Codable, CaseIterable {
    case utf8, western, dos, utf16

    public var title: String {
        switch self {
        case .utf8: return "UTF-8"
        case .western: return "Western (Windows ANSI)"
        case .dos: return "ASCII (DOS)"
        case .utf16: return "Unicode UTF-16"
        }
    }

    /// The encoding of 8-bit text; UTF-16 is handled in both byte orders by the pattern.
    var stringEncoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .western: return .windowsCP1252

        case .dos:
            return String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))

        case .utf16: return .utf16LittleEndian
        }
    }
}

/// The check boxes under "Find text" (spec 09 › "Find text"). "Case sensitive" is a member of
/// `SearchQuery`, where it has always been.
public struct TextSearchOptions: Codable, Equatable {
    public var wholeWords: Bool
    /// The text is a regular expression, matched line by line.
    public var regex: Bool
    /// The text is a string of hex bytes, with quoted literal text in between: `"PK" 03 04`.
    public var hex: Bool
    /// Finds the files that do not contain the text.
    public var notContaining: Bool
    /// A file matches when the text is found in any of these.
    public var encodings: [TextEncoding]

    public init(
        wholeWords: Bool = false, regex: Bool = false, hex: Bool = false, notContaining: Bool = false,
        encodings: [TextEncoding] = [.utf8]
    ) {
        self.wholeWords = wholeWords
        self.regex = regex
        self.hex = hex
        self.notContaining = notContaining
        self.encodings = encodings
    }
}

/// A text to look for inside files, prepared once and then used on many files at the same
/// time (spec 09 › "Find text").
///
/// **Threading.** A pattern is immutable; `isFound` may run on any number of threads at once,
/// each with its own reader. Files are read in blocks and never held in memory as a whole.
public struct TextPattern {
    public enum Problem: LocalizedError, Equatable {
        case emptyText
        case badHex(String)
        case badRegex(String)
        case notRepresentable(String)

        public var errorDescription: String? {
            switch self {
            case .emptyText: return "There is no text to find."
            case .badHex(let text): return "\"\(text)\" is not a string of hex bytes such as 00 FF 12 or \"PK\" 03 04."
            case .badRegex(let reason): return "The regular expression cannot be used: \(reason)"
            case .notRepresentable(let text): return "\"\(text)\" cannot be written in any of the chosen encodings."
            }
        }
    }

    /// One way the text can appear as bytes. Every element is one character (or one byte of a
    /// hex string) with the byte sequences that stand for it: one, or two where upper and lower
    /// case both count.
    struct Needle {
        let elements: [[[UInt8]]]
        /// Bytes per code unit: 2 for UTF-16.
        let unit: Int
        let bigEndian: Bool
        let wholeWords: Bool
        let minLength: Int
        let maxLength: Int
        /// Whether a byte can start the text; most positions of a file are ruled out by this.
        let firstBytes: [Bool]
        /// The bytes of the text when there is only one way to write it; found with `memmem`.
        let literal: [UInt8]?

        init(elements: [[[UInt8]]], unit: Int = 1, bigEndian: Bool = false, wholeWords: Bool) {
            self.elements = elements
            self.unit = unit
            self.bigEndian = bigEndian
            self.wholeWords = wholeWords
            minLength = elements.reduce(0) { $0 + ($1.map(\.count).min() ?? 0) }
            maxLength = elements.reduce(0) { $0 + ($1.map(\.count).max() ?? 0) }
            var first = [Bool](repeating: false, count: 256)
            for alternative in elements.first ?? [] { if let byte = alternative.first { first[Int(byte)] = true } }
            firstBytes = first
            literal = !wholeWords && elements.allSatisfy({ $0.count == 1 }) ? elements.flatMap { $0[0] } : nil
        }

        /// Looks for the text in a piece of a file. `skip` start positions at the front were
        /// judged with the piece before; with `isLast` false, a hit that touches the end of
        /// the piece is left to the next one when the character after it matters.
        func occurs(in hay: UnsafeRawBufferPointer, skip: Int, isLast: Bool) -> Bool {
            guard minLength > 0, hay.count >= minLength, let base = hay.baseAddress else { return false }
            if let literal {
                return literal.withUnsafeBytes { memmem(base, hay.count, $0.baseAddress, $0.count) != nil }
            }
            let bytes = hay.bindMemory(to: UInt8.self)
            // The state of `match`, made once for all the start positions of the piece.
            var positions = [Int](repeating: 0, count: elements.count + 1)
            var tried = [Int](repeating: 0, count: elements.count)
            for start in skip...(hay.count - minLength) where firstBytes[Int(bytes[start])] {
                if match(
                    bytes, at: start, positions: &positions, tried: &tried,
                    accept: { end in
                        !wholeWords
                            || (isBoundary(bytes, before: start) && isBoundary(bytes, after: end, isLast: isLast))
                    })
                {
                    return true
                }
            }
            return false
        }

        /// Tries the alternatives of the elements one after the other, going back to the
        /// element before when one has none left. Iterative, with the state in two arrays: a
        /// text of any length is matched on the small stack of a search thread.
        private func match(
            _ bytes: UnsafeBufferPointer<UInt8>, at start: Int, positions: inout [Int], tried: inout [Int],
            accept: (Int) -> Bool
        ) -> Bool {
            let count = elements.count
            positions[0] = start
            tried[0] = 0
            var element = 0
            while true {
                if element == count {
                    if accept(positions[count]) { return true }
                    // Not accepted (a word continues): look for another way to write the text.
                    element -= 1
                    if element < 0 { return false }
                    continue
                }
                let alternatives = elements[element]
                let position = positions[element]
                var moved = false
                while tried[element] < alternatives.count {
                    let alternative = alternatives[tried[element]]
                    tried[element] += 1
                    guard position + alternative.count <= bytes.count else { continue }
                    var same = true
                    for index in alternative.indices where bytes[position + index] != alternative[index] {
                        same = false
                        break
                    }
                    if same {
                        positions[element + 1] = position + alternative.count
                        moved = true
                        break
                    }
                }
                if moved {
                    element += 1
                    if element < count { tried[element] = 0 }
                } else {
                    element -= 1
                    if element < 0 { return false }
                }
            }
        }

        private func isWordUnit(_ bytes: UnsafeBufferPointer<UInt8>, at position: Int) -> Bool {
            var value = UInt16(bytes[position])
            if unit == 2 {
                let other = UInt16(bytes[position + 1])
                value = bigEndian ? value << 8 | other : other << 8 | value
            }
            // Letters outside ASCII count as parts of words without being looked at closely.
            return value >= 0x80 || value == 0x5F || (0x30...0x39).contains(value) || (0x41...0x5A).contains(value)
                || (0x61...0x7A).contains(value)
        }

        private func isBoundary(_ bytes: UnsafeBufferPointer<UInt8>, before start: Int) -> Bool {
            start < unit || !isWordUnit(bytes, at: start - unit)
        }

        private func isBoundary(_ bytes: UnsafeBufferPointer<UInt8>, after end: Int, isLast: Bool) -> Bool {
            guard end + unit <= bytes.count else { return isLast }
            return !isWordUnit(bytes, at: end)
        }
    }

    private enum Matcher {
        case bytes([Needle])
        case regex(NSRegularExpression, [TextEncoding])
    }

    private let matcher: Matcher
    /// Counts the pieces of files a regular expression ran out of time on.
    let trip = RegexTrip()
    public let notContaining: Bool
    /// The chosen encodings the text cannot be written in; they were left out.
    public let droppedEncodings: [TextEncoding]

    public init(_ text: String, caseSensitive: Bool = false, options: TextSearchOptions = TextSearchOptions()) throws {
        guard !text.isEmpty else { throw Problem.emptyText }
        notContaining = options.notContaining
        let encodings = options.encodings.isEmpty ? [TextEncoding.utf8] : options.encodings
        if options.hex {
            matcher = .bytes([
                Needle(
                    elements: try Self.hexElements(text, caseSensitive: caseSensitive),
                    wholeWords: options.wholeWords)
            ])
            droppedEncodings = []
        } else if options.regex {
            do {
                let pattern = options.wholeWords ? "\\b(?:\(text))\\b" : text
                let regex = try NSRegularExpression(
                    pattern: pattern,
                    options: caseSensitive ? [.anchorsMatchLines] : [.anchorsMatchLines, .caseInsensitive])
                matcher = .regex(regex, encodings)
                droppedEncodings = []
            } catch {
                throw Problem.badRegex(error.localizedDescription)
            }
        } else {
            let plain = Self.unescape(text)
            var needles: [Needle] = []
            var dropped: [TextEncoding] = []
            for encoding in encodings {
                let found = Self.needles(
                    for: plain, in: encoding, caseSensitive: caseSensitive, wholeWords: options.wholeWords)
                if found.isEmpty { dropped.append(encoding) }
                for needle in found
                where !needles.contains(where: { $0.elements == needle.elements && $0.unit == needle.unit }) {
                    needles.append(needle)
                }
            }
            guard !needles.isEmpty else { throw Problem.notRepresentable(text) }
            matcher = .bytes(needles)
            droppedEncodings = dropped
        }
    }

    /// `\t`, `\n` and `\\` of a plain text (spec 09 › "Find text", Escapes).
    static func unescape(_ text: String) -> String {
        var result = ""
        var escaped = false
        for character in text {
            if escaped {
                switch character {
                case "t": result.append("\t")
                case "n": result.append("\n")
                case "\\": result.append("\\")

                default:
                    result.append("\\")
                    result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
    }

    private static func needles(for text: String, in encoding: TextEncoding, caseSensitive: Bool, wholeWords: Bool)
        -> [Needle]
    {
        func elements(_ encoding: String.Encoding) -> [[[UInt8]]]? {
            var elements: [[[UInt8]]] = []
            for character in text {
                let forms =
                    caseSensitive
                    ? [String(character)]
                    : [String(character), String(character).lowercased(), String(character).uppercased()]
                var alternatives: [[UInt8]] = []
                for form in forms {
                    guard let data = form.data(using: encoding, allowLossyConversion: false), !data.isEmpty else {
                        continue
                    }
                    if !alternatives.contains(Array(data)) { alternatives.append(Array(data)) }
                }
                // The character as typed must exist in the encoding; its other case need not.
                guard String(character).data(using: encoding, allowLossyConversion: false)?.isEmpty == false else {
                    return nil
                }
                elements.append(alternatives)
            }
            return elements
        }
        if encoding == .utf16 {
            return [(String.Encoding.utf16LittleEndian, false), (.utf16BigEndian, true)].compactMap {
                order, bigEndian in
                elements(order).map { Needle(elements: $0, unit: 2, bigEndian: bigEndian, wholeWords: wholeWords) }
            }
        }
        return elements(encoding.stringEncoding).map { [Needle(elements: $0, wholeWords: wholeWords)] } ?? []
    }

    /// Reads `00 FF 12` and `"PK"0102`. Without "Case sensitive", the code of a lowercase
    /// letter also finds the uppercase letter; the code of an uppercase letter finds only that.
    static func hexElements(_ text: String, caseSensitive: Bool) throws -> [[[UInt8]]] {
        var bytes: [UInt8] = []
        var digits = ""
        var inQuotes = false
        var literal = ""
        for character in text {
            if inQuotes {
                if character == "\"" {
                    bytes += Array(literal.utf8)
                    (literal, inQuotes) = ("", false)
                } else {
                    literal.append(character)
                }
            } else if character == "\"" {
                guard digits.isEmpty else { throw Problem.badHex(text) }
                inQuotes = true
            } else if character.isHexDigit {
                digits.append(character)
                if digits.count == 2, let byte = UInt8(digits, radix: 16) {
                    bytes.append(byte)
                    digits = ""
                }
            } else if character == " " || character == "," {
                guard digits.isEmpty else { throw Problem.badHex(text) }
            } else {
                throw Problem.badHex(text)
            }
        }
        guard !inQuotes, digits.isEmpty, !bytes.isEmpty else { throw Problem.badHex(text) }
        return bytes.map { byte in
            !caseSensitive && (0x61...0x7A).contains(byte) ? [[byte], [byte - 0x20]] : [[byte]]
        }
    }

    // MARK: Searching

    /// Whether the file passes the text criterion: the text is in it, or, with "NOT
    /// containing", is not. A file that cannot be read never passes.
    public func accepts(_ reader: any FileReader, cancellation: CancellationFlag? = nil, blockSize: Int = 1 << 20)
        -> Bool
    {
        guard let found = search(reader, cancellation: cancellation, blockSize: blockSize) else { return false }
        return found != notContaining
    }

    /// Whether the text occurs in the bytes the reader delivers.
    public func isFound(in reader: any FileReader, cancellation: CancellationFlag? = nil, blockSize: Int = 1 << 20)
        -> Bool
    {
        search(reader, cancellation: cancellation, blockSize: blockSize) ?? false
    }

    public func isFound(in data: Data, blockSize: Int = 1 << 20) -> Bool {
        isFound(in: DataReader(data), blockSize: blockSize)
    }

    /// Nil when the search was cancelled or the file could not be read to its end.
    private func search(_ reader: any FileReader, cancellation: CancellationFlag?, blockSize: Int) -> Bool? {
        switch matcher {
        case .bytes(let needles): return Self.search(needles, reader, cancellation, blockSize)

        case .regex(let regex, let encodings):
            return Self.search(regex, encodings, reader, cancellation, blockSize, trip)
        }
    }

    /// Reads block by block. The end of each block is looked at again together with the next
    /// one, so a hit across a block border is found, with the characters around it.
    private static func search(
        _ needles: [Needle], _ reader: any FileReader, _ cancellation: CancellationFlag?, _ blockSize: Int
    ) -> Bool? {
        let overlap = (needles.map(\.maxLength).max() ?? 1) + 2
        var carry = Data()
        var carryStartsFile = true
        do {
            var current = try reader.read(upToCount: blockSize)
            while let block = current {
                if cancellation?.isCancelled == true { return nil }
                // The blocks are big and short-lived: a search thread frees them as it goes.
                let outcome: Bool? = try autoreleasepool {
                    let next = try reader.read(upToCount: blockSize)
                    let isLast = next?.isEmpty ?? true
                    let buffer = carry + block
                    let isStart = carry.isEmpty || carryStartsFile
                    let found = buffer.withUnsafeBytes { hay in
                        needles.contains { $0.occurs(in: hay, skip: isStart ? 0 : $0.unit, isLast: isLast) }
                    }
                    if found { return true }
                    if isLast { return false }
                    carryStartsFile = carryStartsFile && buffer.count <= overlap
                    carry = Data(buffer.suffix(overlap))
                    current = next
                    return nil
                }
                if let outcome { return outcome }
            }
        } catch {
            return nil
        }
        return false
    }

    /// Decodes the file in pieces that end at a line break and matches each piece with `^` and
    /// `$` standing for the line ends, which is matching line by line without cutting the
    /// text into lines. A piece that takes the expression too long ends the search of the file
    /// (it is not found in it), and a cancelled search ends at once, also in the middle of a piece.
    private static func search(
        _ regex: NSRegularExpression, _ encodings: [TextEncoding], _ reader: any FileReader,
        _ cancellation: CancellationFlag?, _ blockSize: Int, _ trip: RegexTrip
    ) -> Bool? {
        var decoders = encodings.map { LineDecoder(encoding: $0) }
        var gaveUp = false
        func matches(_ text: String?) -> Bool {
            guard let text, !text.isEmpty, !gaveUp else { return false }
            if trip.isTripped {
                gaveUp = true
                return false
            }
            switch FindRegex.firstMatch(
                regex, in: text, budget: pieceBudget, cancelled: { cancellation?.isCancelled == true })
            {
            case .matched: return true
            case .unmatched: return false

            case .timedOut:
                gaveUp = true
                if cancellation?.isCancelled != true { trip.recordTimeout() }
                return false
            }
        }
        enum Step { case hit, more, end, stop }
        do {
            reading: while true {
                let step: Step = try autoreleasepool {
                    guard let block = try reader.read(upToCount: blockSize), !block.isEmpty else { return .end }
                    if cancellation?.isCancelled == true { return .stop }
                    for index in decoders.indices where matches(decoders[index].feed(block)) { return .hit }
                    return gaveUp ? .stop : .more
                }
                switch step {
                case .hit: return true
                case .more: continue reading
                case .stop: return nil
                case .end: break reading
                }
            }
        } catch {
            return nil
        }
        return decoders.indices.contains { matches(decoders[$0].finish()) } ? true : (gaveUp ? nil : false)
    }

    /// What one piece of a file may take a regular expression.
    static let pieceBudget: TimeInterval = 2

    /// Collects the bytes of a file and hands them out as text, whole lines at a time.
    private struct LineDecoder {
        let encoding: TextEncoding
        private var pending = Data()
        private var bigEndian = false
        private var isStart = true
        /// A "line" longer than this is handed out in pieces.
        private static let longestLine = 4 << 20

        init(encoding: TextEncoding) {
            self.encoding = encoding
        }

        /// How much of a piece cut in the middle of a long line is looked at again with the next one,
        /// so that a match across the cut is found as long as it is shorter than this.
        private static let cutOverlap = 4_096

        mutating func feed(_ block: Data) -> String? {
            pending.append(block)
            if isStart, encoding == .utf16, pending.count >= 2 {
                let mark = (pending[pending.startIndex], pending[pending.startIndex + 1])
                if mark == (0xFE, 0xFF) { bigEndian = true }
                if mark == (0xFE, 0xFF) || mark == (0xFF, 0xFE) {
                    pending.removeFirst(2)
                } else {
                    // Without a mark, text in the Latin range shows in the zero bytes: they come
                    // first in the big-endian order, after the letter in the little-endian one.
                    var (even, odd) = (0, 0)
                    for (offset, byte) in pending.prefix(256).enumerated() where byte == 0 {
                        if offset % 2 == 0 { even += 1 } else { odd += 1 }
                    }
                    bigEndian = even > odd
                }
                isStart = false
            }
            if let cut = lastLineEnd(), cut > 0 {
                let text = decode(pending.prefix(cut))
                pending.removeFirst(cut)
                return text
            }
            guard pending.count > Self.longestLine else { return nil }
            // A line without a break that is too long: handed out in pieces, cut between
            // characters, with the end of each piece repeated at the start of the next.
            let cut = boundary(atOrBefore: pending.count)
            guard cut > 0 else { return nil }
            let text = decode(pending.prefix(cut))
            pending.removeFirst(boundary(atOrBefore: max(0, cut - Self.cutOverlap)))
            return text
        }

        /// The nearest place at or before `position` where a character starts.
        private func boundary(atOrBefore position: Int) -> Int {
            switch encoding {
            case .utf8:
                if position >= pending.count {
                    // The end of what there is: a character that is not all here yet waits for the next piece.
                    var lead = pending.count - 1
                    var back = 0
                    while lead > 0, back < 3, pending[pending.startIndex + lead] & 0xC0 == 0x80 {
                        lead -= 1
                        back += 1
                    }
                    guard lead >= 0, !pending.isEmpty else { return pending.count }
                    let byte = pending[pending.startIndex + lead]
                    let needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
                    return lead + needed > pending.count ? lead : pending.count
                }
                var index = position
                while index > 0, pending[pending.startIndex + index] & 0xC0 == 0x80 { index -= 1 }
                return index

            case .utf16:
                return position / 4 * 4

            case .western, .dos:
                return position
            }
        }

        mutating func finish() -> String? {
            defer { pending = Data() }
            return decode(pending)
        }

        /// The number of bytes up to and including the last line break.
        private func lastLineEnd() -> Int? {
            // Looked at in place, from the end: no copy of the bytes, and it stops at the line end.
            pending.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int? in
                guard encoding == .utf16 else {
                    var index = bytes.count - 1
                    while index >= 0 {
                        if bytes[index] == 0x0A { return index + 1 }
                        index -= 1
                    }
                    return nil
                }
                var index = bytes.count / 2 * 2 - 2
                while index >= 0 {
                    let (line, zero) = bigEndian ? (bytes[index + 1], bytes[index]) : (bytes[index], bytes[index + 1])
                    if line == 0x0A, zero == 0 { return index + 2 }
                    index -= 2
                }
                return nil
            }
        }

        private func decode(_ data: Data) -> String? {
            switch encoding {
            case .utf8: return String(decoding: data, as: UTF8.self)

            case .utf16:
                return String(
                    data: data.prefix(data.count / 2 * 2), encoding: bigEndian ? .utf16BigEndian : .utf16LittleEndian)

            case .western, .dos:
                return String(data: data, encoding: encoding.stringEncoding)
                    ?? String(data: data, encoding: .isoLatin1)
            }
        }
    }

    private final class DataReader: FileReader {
        private let data: Data
        private var position = 0

        init(_ data: Data) { self.data = data }

        func read(upToCount count: Int) -> Data? {
            guard position < data.count else { return nil }
            let end = min(position + count, data.count)
            defer { position = end }
            return data.subdata(in: position..<end)
        }

        func seek(to offset: UInt64) { position = min(Int(clamping: offset), data.count) }
        func close() {}
    }
}
