import Foundation

/// Reads encoded text line by line and recognises by itself what it is (spec 08 › Decode):
/// MIME/Base64 with or without mail headers, UUEncode (also `begin-base64`), XXEncode and
/// yEnc.
///
/// The lines of several part files are fed one after the other.
///
/// Whatever the encoded text itself lets one check is checked: the end marks, the size and
/// `sum -r` of UUEncode, the size and CRC32 of yEnc, the padding of Base64. What does not
/// hold is collected in `problems`; the decoded bytes are written all the same, so the caller
/// can keep the file and say that it is incomplete or damaged.
internal final class DecodeMachine {
    /// What the machine is reading.
    internal enum State {
        /// `endsAtMark`: `begin-base64` text ends with `====`. `mime`: the body came after mail headers,
        /// where a line starting with `--` is a boundary (`-` is no Base64 digit there).
        case base64(endsAtMark: Bool, mime: Bool)
        /// The headers of a mail part, with the name they gave so far and whether the body is Base64.
        case mimeHeaders(name: String?, isBase64: Bool)
        /// Looking for the start of an encoded file.
        case searching
        /// The lines of UUEncode or XXEncode, in the alphabet found so far.
        case sixBit(SixBitAlphabet)
        /// The lines of yEnc.
        case yEnc
    }

    /// Which of the two alphabets of six-bit text a file is in.
    internal enum SixBitAlphabet {
        /// Not known until the first line shows it.
        case unknown
        /// UUEncode.
        case uuEncode
        /// XXEncode.
        case xxEncode
    }

    /// What the end of a UUEncode/XXEncode file is checked against once its `sum -r/size` line has (or has
    /// not) come.
    internal struct SixBitTally {
        /// The name of the file.
        internal var name: String?
        /// The `sum -r` of the bytes decoded.
        internal var sum: UInt32 = 0
        /// The bytes decoded.
        internal var size: Int64 = 0
        /// The lines passed over because they were not of the format.
        internal var skippedLines = 0
        /// The short lines that were not the last one.
        internal var shortLinesInside = 0
        /// The bytes of the last line.
        internal var lastCount: Int?
        /// The bytes of the first line, which a full line has.
        internal var fullCount: Int?
    }

    /// The value of each byte as a Base64 character; 255 for the others.
    internal static let base64Values: [UInt8] = {
        var values = [UInt8](repeating: 255, count: 256)
        for (index, character) in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8.enumerated() {
            values[Int(character)] = UInt8(index)
        }
        // The URL-safe alphabet is read as well.
        values[Int(UInt8(ascii: "-"))] = 62
        values[Int(UInt8(ascii: "_"))] = 63
        return values
    }()

    /// Where the decoded files go.
    internal let sink: any DecodeSink
    /// What the machine is reading.
    internal var state = State.searching
    /// The Base64 digits read and not decoded yet.
    internal var sextets: [UInt8] = []
    /// The files decoded so far.
    internal private(set) var filesDecoded = 0
    /// What is wrong with the files decoded so far; empty when everything that can be checked holds.
    internal private(set) var problems: [String] = []
    /// False until anything but white space was seen; only then can plain Base64 start.
    internal var sawText = false
    /// The name of the file being decoded.
    private var currentName: String?

    // The body of Base64 text: how its lines look, to tell a part that goes on from one that ends.

    /// The lines of the Base64 body so far.
    internal var bodyLines = 0
    /// The length of its first line.
    internal var firstLineLength = 0
    /// The length of its last line.
    internal var lastLineLength = 0
    /// The characters passed over that are not Base64.
    internal var strayCharacters = 0
    /// Whether the end mark of `begin-base64` came.
    internal var sawEndMark = false

    /// What the UUEncode/XXEncode file being decoded is checked against.
    internal var tally = SixBitTally()
    /// A finished UUEncode/XXEncode file waits for the `sum -r/size` line that may follow `end`.
    internal var awaitingTrailer: SixBitTally?

    /// The bytes of the yEnc file decoded so far.
    internal var yBytes: Int64 = 0
    /// Their CRC32.
    internal var yCRC = CRC32Hasher()
    /// The size the `=ybegin` line gives.
    internal var yHeaderSize: Int64?
    /// The length the `=ypart` line gives, when its range is valid.
    internal var yPartLength: Int64?
    /// Whether a `=ypart` line came: the file is one part of several.
    internal var yHasPart = false

    /// Whether a file is being decoded whose end has not come yet: the next part is needed.
    internal var isInsideFile: Bool {
        if case .searching = state {
            return false
        }
        if case .mimeHeaders = state {
            return false
        }
        return true
    }

    /// Whether the next numbered file can belong to what is being decoded.
    ///
    /// A structured format (UUEncode, XXEncode, yEnc, `begin-base64`) goes on until its end mark.
    /// Plain Base64 has no end mark: it goes on only where the text breaks off inside a group of
    /// four, or on a full line (the parts the encoder writes break off after full lines); otherwise
    /// it ended.
    internal var needsMoreParts: Bool {
        switch state {
        case .searching, .mimeHeaders:
            return false

        case .sixBit, .yEnc:
            return true

        case .base64(let endsAtMark, _):
            if endsAtMark {
                return true
            }
            let fullLine = lastLineLength >= 76 || (bodyLines >= 2 && lastLineLength == firstLineLength)
            return !sextets.count.isMultiple(of: 4) || fullLine
        }
    }

    /// A machine that puts what it decodes into `sink`.
    internal init(sink: any DecodeSink) {
        self.sink = sink
    }

    /// Whether a line opens a new encoded file or mail part: where a Base64 body ends even
    /// without padding or a boundary, and what an independent next file starts with.
    internal static func startsNewFile(_ line: ArraySlice<UInt8>) -> Bool {
        func has(_ prefix: String, folded: Bool) -> Bool {
            let wanted = Array(prefix.utf8)
            guard line.count >= wanted.count else {
                return false
            }
            return zip(line, wanted)
                .allSatisfy { byte, letter in
                    (folded && byte >= 65 && byte <= 90 ? byte + 32 : byte) == letter
                }
        }
        return has("mime-version:", folded: true) || has("content-", folded: true) || has("begin ", folded: false)
    }

    /// A line as text: UTF-8, else Latin-1, which takes every byte as the character of its value.
    internal func text(_ bytes: ArraySlice<UInt8>) -> String {
        String(bytes: bytes, encoding: .utf8)
            ?? String(String.UnicodeScalarView(bytes.map { byte in Unicode.Scalar(byte) }))
    }

    /// Notes a problem of the file being decoded.
    internal func report(_ message: String) {
        problems.append("\(currentName ?? "(no name)"): \(message)")
    }

    /// Notes a problem of a file, already named.
    internal func reportNamed(_ message: String) {
        problems.append(message)
    }

    /// Starts a file named `name` and reads on in `next`.
    internal func open(_ name: String?, _ next: State) throws {
        try sink.begin(name: name)
        sextets = []
        state = next
        currentName = name
        bodyLines = 0
        firstLineLength = 0
        lastLineLength = 0
        strayCharacters = 0
        sawEndMark = false
        tally = SixBitTally(name: name)
        yBytes = 0
        yCRC = CRC32Hasher()
        yHeaderSize = nil
        yPartLength = nil
        yHasPart = false
    }

    /// Ends the file being decoded, and looks for the next.
    internal func close() throws {
        if case .base64 = state {
            try flushBase64(final: true)
        }
        try sink.end()
        filesDecoded += 1
        state = .searching
    }

    /// Ends what is open when the input is over, and says what was missing.
    internal func finish() throws {
        switch state {
        case .sixBit:
            report("the end line is missing: the text is incomplete (a part may be missing)")

        case .yEnc:
            report("the =yend line is missing: the text is incomplete (a part may be missing)")

        case .base64(let endsAtMark, _):
            if endsAtMark, !sawEndMark {
                report("the end mark is missing: the text is incomplete")
            }

        case .searching, .mimeHeaders:
            break
        }
        if isInsideFile {
            try close()
        }
        if let pending = awaitingTrailer {
            check(pending, against: nil)
        }
    }

    /// Reads one line (without its line break).
    internal func feed(_ line: ArraySlice<UInt8>) throws {
        if awaitingTrailer != nil, case .searching = state, resolveTrailer(with: line) {
            return
        }
        switch state {
        case .searching:
            try search(line)

        case .mimeHeaders(let name, let isBase64):
            try readHeader(line, name: name, isBase64: isBase64)

        case .base64(let endsAtMark, let mime):
            try readBase64(line, endsAtMark: endsAtMark, mime: mime)

        case .sixBit(let alphabet):
            try readSixBit(line, alphabet: alphabet)

        case .yEnc:
            try readYEnc(line)
        }
    }

    /// Looks at a line for the start of an encoded file: `begin-base64`, `begin`, `=ybegin`, mail headers, or
    /// plain Base64 from the first line on.
    private func search(_ line: ArraySlice<UInt8>) throws {
        guard !line.isEmpty else {
            return
        }
        defer { sawText = true }
        if line.starts(with: Array("begin-base64 ".utf8)) {
            let fields = text(line).split(separator: " ", maxSplits: 2).map(String.init)
            try open(fields.count == 3 ? fields[2] : nil, .base64(endsAtMark: true, mime: false))
        } else if line.starts(with: Array("begin ".utf8)) {
            let fields = text(line).split(separator: " ", maxSplits: 2).map(String.init)
            guard fields.count >= 2, fields[1].allSatisfy({ digit in ("0"..."7").contains(digit) }) else {
                return
            }
            try open(fields.count == 3 ? fields[2] : nil, .sixBit(.unknown))
        } else if line.starts(with: Array("=ybegin ".utf8)) {
            let header = text(line)
            try open(header.range(of: " name=").map { range in String(header[range.upperBound...]) }, .yEnc)
            yHeaderSize = yParameter("size", in: header).flatMap { size in Int64(size) }
        } else if case let lowered = text(line.prefix(40)).lowercased(),
            lowered.hasPrefix("mime-version:") || lowered.hasPrefix("content-")
        {
            state = .mimeHeaders(name: nil, isBase64: false)
            try feed(line)
        } else if !sawText, filesDecoded == 0,
            line.allSatisfy({ byte in Self.base64Values[Int(byte)] != 255 || byte == UInt8(ascii: "=") })
        {
            // Nothing but Base64 from the first line on: the output of `base64`.
            try open(nil, .base64(endsAtMark: false, mime: false))
            try feed(line)
        }
    }

    /// Reads a line of mail headers: the name of the file and whether the body is Base64; the empty line ends
    /// them.
    private func readHeader(_ line: ArraySlice<UInt8>, name: String?, isBase64: Bool) throws {
        if line.isEmpty {
            if isBase64 {
                try open(name, .base64(endsAtMark: false, mime: true))
            } else {
                state = .searching
            }
            return
        }
        let header = text(line)
        var base64 = isBase64
        if header.lowercased().hasPrefix("content-transfer-encoding:") {
            base64 = header.lowercased().contains("base64")
        }
        let named = parameter("filename", in: header) ?? name ?? parameter("name", in: header)
        state = .mimeHeaders(name: named, isBase64: base64)
    }

    /// A value of a header line: `name="x"` or `name=x`.
    private func parameter(_ key: String, in line: String) -> String? {
        guard let range = line.range(of: key + "=", options: .caseInsensitive) else {
            return nil
        }
        // `filename=` must not be found inside another word, nor `name=` inside `filename=`.
        if range.lowerBound > line.startIndex, case let before = line[line.index(before: range.lowerBound)],
            before.isLetter || before == "-"
        {
            return parameter(key, in: String(line[range.upperBound...]))
        }
        let rest = line[range.upperBound...]
        if rest.hasPrefix("\"") {
            return rest.dropFirst().split(separator: "\"", omittingEmptySubsequences: false).first.map(String.init)
        }
        return rest.split { character in character == ";" || character == " " }.first.map(String.init)
    }

    deinit {
        // Nothing to release.
    }
}
