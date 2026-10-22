import AFMKernel
import Foundation

/// The formats of Encode File (spec 08 › Encode).
///
/// The raw values are those of the spec's `EncodeMethod` setting.
enum EncodeMethod: Int, CaseIterable {
    case mime = 0
    case uue, xxe

    var title: String {
        switch self {
        case .mime: return "MIME (Base64)"
        case .uue: return "UUEncode"
        case .xxe: return "XXEncode"
        }
    }

    var fileExtension: String {
        switch self {
        case .mime: return "b64"
        case .uue: return "uue"
        case .xxe: return "xxe"
        }
    }

    /// The bytes of the original one full line carries.
    var bytesPerLine: Int { self == .mime ? 57 : 45 }
    /// The length of a full line with its CRLF.
    var lineLength: Int { self == .mime ? 78 : 63 }
}

/// The alphabets of the two older formats, and their lines.
enum SixBitText {
    static let xxAlphabet = Array("+-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    /// The character of every six-bit value in each alphabet.
    private static let uuCharacters: [UInt8] = (0..<64).map { $0 == 0 ? 96 : UInt8($0) + 32 }
    /// The six-bit value of every character in each alphabet; 255 for the others.
    private static let uuValues: [UInt8] = (0..<256).map { (32...96).contains($0) ? UInt8((($0 - 32) & 63)) : 255 }
    private static let xxValues: [UInt8] = {
        var values = [UInt8](repeating: 255, count: 256)
        for (index, character) in xxAlphabet.enumerated() { values[Int(character)] = UInt8(index) }
        return values
    }()

    /// Lines of up to 45 bytes each: a length character, four characters for every three
    /// bytes, CRLF.
    static func encode(_ data: Data, xx: Bool) -> Data {
        let (full, rest) = data.count.quotientAndRemainder(dividingBy: 45)
        var output = Data(count: full * 63 + (rest > 0 ? 3 + (rest + 2) / 3 * 4 : 0))
        guard !output.isEmpty else { return output }
        let characters = xx ? xxAlphabet : uuCharacters
        output.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                characters.withUnsafeBufferPointer { table in
                    let (source, target) = (input.bindMemory(to: UInt8.self), out.bindMemory(to: UInt8.self))
                    var (position, written) = (0, 0)
                    while position < source.count {
                        let count = min(45, source.count - position)
                        target[written] = table[count]
                        written += 1
                        var group = 0
                        while group < count {
                            // A last group of fewer than three bytes is read as if padded with zeros.
                            let a = source[position + group]
                            let b = group + 1 < count ? source[position + group + 1] : 0
                            let c = group + 2 < count ? source[position + group + 2] : 0
                            target[written] = table[Int(a >> 2)]
                            target[written + 1] = table[Int((a << 4 | b >> 4) & 63)]
                            target[written + 2] = table[Int((b << 2 | c >> 6) & 63)]
                            target[written + 3] = table[Int(c & 63)]
                            written += 4
                            group += 3
                        }
                        target[written] = 13
                        target[written + 1] = 10
                        written += 2
                        position += count
                    }
                }
            }
        }
        return output
    }

    /// The bytes of one line, nil when the line is not one of this format.
    static func decode(_ line: ArraySlice<UInt8>, xx: Bool) -> [UInt8]? {
        (xx ? xxValues : uuValues)
            .withUnsafeBufferPointer { table in
                line.withUnsafeBufferPointer { text -> [UInt8]? in
                    guard let first = text.first, table[Int(first)] != 255 else { return nil }
                    let count = Int(table[Int(first)])
                    // Every character of the line must belong to the alphabet.
                    for index in 1..<max(text.count, 1) where table[Int(text[index])] == 255 { return nil }
                    let available = text.count - 1
                    let needed = (count + 2) / 3 * 4
                    // Programs that cut spaces off the end of a line leave UUEncode lines short.
                    guard available >= needed || (!xx && available + 3 >= needed) else { return nil }
                    // An empty array is never made with `unsafeUninitializedCapacity`: for a capacity of zero
                    // the standard library writes the count into the storage all empty arrays share, a write
                    // that races with any other thread reading an empty array.
                    guard count > 0 else { return [] }
                    return [UInt8](unsafeUninitializedCapacity: count) { bytes, initialized in
                        func six(_ index: Int) -> UInt8 { index < available ? table[Int(text[index + 1])] : 0 }
                        var (group, written) = (0, 0)
                        while written < count {
                            let (a, b, c, d) = (six(group), six(group + 1), six(group + 2), six(group + 3))
                            bytes[written] = a << 2 | b >> 4
                            if written + 1 < count { bytes[written + 1] = b << 4 | c >> 2 }
                            if written + 2 < count { bytes[written + 2] = c << 6 | d }
                            written += 3
                            group += 4
                        }
                        initialized = count
                    }
                }
            }
    }
}

/// Encode File (spec 08 › Encode, Encoded output format).
enum Encoder {
    /// The names of the encoded files: one file keeps the base name, several are numbered
    /// `name001.uue`, `name002.uue`, … which is what Decode looks for.
    static func outputNames(for name: String, method: EncodeMethod, parts: Int) -> [String] {
        let base = FileItem.split(name).base
        guard parts > 1 else { return [base + "." + method.fileExtension] }
        return (1...parts).map { base + String(format: "%03d", $0) + "." + method.fileExtension }
    }

    /// How many lines go into one file: the smaller of the two limits, 0 for no limit.
    ///
    /// "Bytes per file" counts the encoded text without the header.
    static func linesPerFile(lines: Int, bytes: Int64, method: EncodeMethod) -> Int {
        let fromBytes = bytes > 0 ? max(1, Int(min(bytes / Int64(method.lineLength), Int64(Int32.max)))) : 0
        if lines > 0, fromBytes > 0 { return min(lines, fromBytes) }
        return max(lines, fromBytes)
    }

    static func header(for name: String, method: EncodeMethod) -> String {
        switch method {
        case .mime:
            let quoted = name.replacingOccurrences(of: "\"", with: "_")
            return
                "MIME-Version: 1.0\r\nContent-Type: application/octet-stream; name=\"\(quoted)\"\r\nContent-Transfer-Encoding: base64\r\n"
                + "Content-Disposition: attachment; filename=\"\(quoted)\"\r\n\r\n"

        case .uue, .xxe:
            return "begin 644 \(name)\r\n"
        }
    }

    /// Encodes `source` into `directory` and returns the files written; on failure or cancel
    /// none of them is left, and a file that was there before is never touched (see `Splitter.split`).
    @discardableResult
    static func encode(
        _ source: FileItem,
        into directory: URL,
        method: EncodeMethod,
        linesPerFile: Int = 0,
        bytesPerFile: Int64 = 0,
        run: ToolRun
    ) throws -> [URL] {
        run.carriesOrigin = true
        let limit = Self.linesPerFile(lines: linesPerFile, bytes: bytesPerFile, method: method)
        // (The size is what a file system says and the limit what the user typed: neither may overflow a sum.)
        let totalLines = Int(
            max(0, source.size).addingSaturated(Int64(method.bytesPerLine) - 1) / Int64(method.bytesPerLine)
        )
        // Counted before the names are made: a size of exabytes, said by a server, is not a list of that many names.
        let parts = limit > 0 ? max(1, totalLines.addingSaturated(limit - 1) / limit) : 1
        guard parts <= 999 else {
            throw ToolError.failed("With these limits the file would be encoded into more than 999 parts.")
        }
        let names = outputNames(for: source.name, method: method, parts: parts)
        // No output may be the source itself (encoding `notes.b64` as MIME in place): it would be replaced.
        guard !names.contains(where: { ToolRun.isSameFile(directory.appending(name: $0), source.url) }) else {
            throw ToolError.failed("The encoded file would replace \(source.name) itself.")
        }
        // The source is opened before anything is created.
        let reader = try run.openReader(source.url)
        var readerIsOpen = true
        defer { if readerIsOpen { reader.close() } }
        run.expect(bytes: source.size, items: 0)
        // The most bytes of text one file takes; a huge limit is no limit.
        let capacity = limit > 0 ? limit.multipliedReportingOverflow(by: method.lineLength).partialValue : Int.max
        let hasCapacity = limit > 0 && !limit.multipliedReportingOverflow(by: method.lineLength).overflow

        return try run.transaction {
            var written: [URL] = []
            var output: ToolOutput?
            /// The encoded bytes in the current file, without the header.
            var bodyBytes = 0
            var checksum: UInt32 = 0
            var size: Int64 = 0
            var carry = Data()

            func open() throws -> ToolOutput {
                // The source may have grown since the panel listed it; more parts than names are not made up.
                guard written.count < names.count else {
                    throw ToolError.failed(
                        "\(source.name) changed while it was encoded (it needs more parts than planned)."
                    )
                }
                let url = directory.appending(name: names[written.count])
                run.show([
                    "From: " + run.fileSystems.displayPath(source.url), "To: " + run.fileSystems.displayPath(url)
                ])
                guard let part = try run.create(url, deferred: true) else { throw ToolError.cancelled }
                written.append(part.url)
                bodyBytes = 0
                return part
            }

            /// Writes whole lines, going on to the next file where the limit is reached.
            func write(_ text: Data) throws {
                var offset = 0
                let room = hasCapacity ? capacity : Int.max
                while offset < text.count {
                    if hasCapacity, bodyBytes == room {
                        try output?.finish()
                        output = try open()
                    }
                    let chunk = min(room - bodyBytes, text.count - offset)
                    try output?.write(text.subdata(in: (text.startIndex + offset)..<(text.startIndex + offset + chunk)))
                    bodyBytes += chunk
                    offset += chunk
                }
            }

            func encoded(_ data: Data) -> Data {
                switch method {
                case .mime:
                    return data.base64EncodedData(options: [
                        .lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed
                    ]) + Data([13, 10])

                case .uue, .xxe: return SixBitText.encode(data, xx: method == .xxe)
                }
            }

            output = try open()
            readerIsOpen = false
            try output?.write(Data(header(for: source.name, method: method).utf8))
            try run.read(reader) { block in
                size += Int64(block.count)
                if method != .mime {
                    // The checksum of Unix `sum -r`: a 16-bit sum that is rotated before every byte.
                    block.withUnsafeBytes { bytes in
                        for byte in bytes {
                            checksum = ((checksum >> 1) + ((checksum & 1) << 15) + UInt32(byte)) & 0xFFFF
                        }
                    }
                }
                carry.append(block)
                let whole = carry.count - carry.count % method.bytesPerLine
                guard whole > 0 else { return }
                try write(encoded(carry.prefix(whole)))
                carry = Data(carry.dropFirst(whole))
            }
            if !carry.isEmpty { try write(encoded(carry)) }
            switch method {
            case .mime: break
            case .uue: try output?.write(Data("`\r\nend\r\nsum -r/size \(checksum)/\(size)\r\n".utf8))
            case .xxe: try output?.write(Data("+\r\nend\r\nsum -r/size \(checksum)/\(size)\r\n".utf8))
            }
            try output?.finish()
            return written
        }
    }
}

/// Where a decoder puts what it finds.
protocol DecodeSink: AnyObject {
    /// A file starts; `name` is as the encoded text gives it, nil when it gives none.
    func begin(name: String?) throws
    func write(_ bytes: [UInt8]) throws
    func end() throws
}

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
final class DecodeMachine {
    private enum State {
        case searching
        case mimeHeaders(name: String?, isBase64: Bool)
        /// `endsAtMark`: `begin-base64` text ends with `====`. `mime`: the body came after mail headers,
        /// where a line starting with `--` is a boundary (`-` is no Base64 digit there).
        case base64(endsAtMark: Bool, mime: Bool)
        /// `xx` is nil until the first line shows which of the two alphabets it is.
        case sixBit(xx: Bool?)
        case yEnc
    }

    /// What the end of a UUEncode/XXEncode file is checked against once its `sum -r/size` line has (or has not) come.
    private struct SixBitTally {
        var name: String?
        var sum: UInt32 = 0
        var size: Int64 = 0
        var skippedLines = 0
        var shortLinesInside = 0
        var lastCount: Int?
        var fullCount: Int?
    }

    private let sink: any DecodeSink
    private var state = State.searching
    private var sextets: [UInt8] = []
    private(set) var filesDecoded = 0
    /// What is wrong with the files decoded so far; empty when everything that can be checked holds.
    private(set) var problems: [String] = []
    /// False until anything but white space was seen; only then can plain Base64 start.
    private var sawText = false
    private var currentName: String?

    // The body of Base64 text: how its lines look, to tell a part that goes on from one that ends.
    private var bodyLines = 0
    private var firstLineLength = 0
    private var lastLineLength = 0
    private var strayCharacters = 0
    private var sawEndMark = false

    private var tally = SixBitTally()
    /// A finished UUEncode/XXEncode file waits for the `sum -r/size` line that may follow `end`.
    private var awaitingTrailer: SixBitTally?

    private var yBytes: Int64 = 0
    private var yCRC = CRC32Hasher()
    private var yHeaderSize: Int64?
    private var yPartLength: Int64?
    private var yHasPart = false

    init(sink: any DecodeSink) {
        self.sink = sink
    }

    /// Whether a file is being decoded whose end has not come yet: the next part is needed.
    var isInsideFile: Bool {
        if case .searching = state { return false }
        if case .mimeHeaders = state { return false }
        return true
    }

    /// Whether the next numbered file can belong to what is being decoded.
    ///
    /// A structured format (UUEncode, XXEncode, yEnc, `begin-base64`) goes on until its end mark.
    /// Plain Base64 has no end mark: it goes on only where the text breaks off inside a group of
    /// four, or on a full line (the parts the encoder writes break off after full lines); otherwise
    /// it ended.
    var needsMoreParts: Bool {
        switch state {
        case .searching, .mimeHeaders: return false
        case .sixBit, .yEnc: return true

        case .base64(let endsAtMark, _):
            if endsAtMark { return true }
            let fullLine = lastLineLength >= 76 || (bodyLines >= 2 && lastLineLength == firstLineLength)
            return sextets.count % 4 != 0 || fullLine
        }
    }

    /// The value of each byte as a Base64 character; 255 for the others.
    private static let base64Values: [UInt8] = {
        var values = [UInt8](repeating: 255, count: 256)
        for (index, character) in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8.enumerated() {
            values[Int(character)] = UInt8(index)
        }
        // The URL-safe alphabet is read as well.
        values[Int(UInt8(ascii: "-"))] = 62
        values[Int(UInt8(ascii: "_"))] = 63
        return values
    }()

    /// Whether a line opens a new encoded file or mail part: where a Base64 body ends even
    /// without padding or a boundary, and what an independent next file starts with.
    static func startsNewFile(_ line: ArraySlice<UInt8>) -> Bool {
        func has(_ prefix: String, folded: Bool) -> Bool {
            let wanted = Array(prefix.utf8)
            guard line.count >= wanted.count else { return false }
            return zip(line, wanted).allSatisfy { (folded && $0 >= 65 && $0 <= 90 ? $0 + 32 : $0) == $1 }
        }
        return has("mime-version:", folded: true) || has("content-", folded: true) || has("begin ", folded: false)
    }

    /// A line as text: UTF-8, else Latin-1, which takes every byte as the character of its value.
    private func text(_ bytes: ArraySlice<UInt8>) -> String {
        String(bytes: bytes, encoding: .utf8) ?? String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
    }

    private func report(_ message: String) {
        problems.append("\(currentName ?? "(no name)"): \(message)")
    }

    private func open(_ name: String?, _ next: State) throws {
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

    private func close() throws {
        if case .base64 = state { try flushBase64(final: true) }
        try sink.end()
        filesDecoded += 1
        state = .searching
    }

    /// Ends what is open when the input is over, and says what was missing.
    func finish() throws {
        switch state {
        case .sixBit: report("the end line is missing: the text is incomplete (a part may be missing)")
        case .yEnc: report("the =yend line is missing: the text is incomplete (a part may be missing)")

        case .base64(let endsAtMark, _):
            if endsAtMark, !sawEndMark { report("the end mark is missing: the text is incomplete") }

        case .searching, .mimeHeaders: break
        }
        if isInsideFile { try close() }
        if let pending = awaitingTrailer { check(pending, against: nil) }
    }

    private func flushBase64(final: Bool) throws {
        let groups = sextets.count / 4
        var bytes = [UInt8](repeating: 0, count: groups * 3 + 3)
        var length = 0
        sextets.withUnsafeBufferPointer { s in
            bytes.withUnsafeMutableBufferPointer { out in
                for group in 0..<groups {
                    let (a, b, c, d) = (s[group * 4], s[group * 4 + 1], s[group * 4 + 2], s[group * 4 + 3])
                    out[group * 3] = a << 2 | b >> 4
                    out[group * 3 + 1] = b << 4 | c >> 2
                    out[group * 3 + 2] = c << 6 | d
                }
                length = groups * 3
                if final {
                    let rest = s.count - groups * 4
                    if rest >= 2 {
                        out[length] = s[groups * 4] << 2 | s[groups * 4 + 1] >> 4
                        length += 1
                    }
                    if rest == 3 {
                        out[length] = s[groups * 4 + 1] << 4 | s[groups * 4 + 2] >> 2
                        length += 1
                    }
                }
            }
        }
        sextets.removeFirst(groups * 4)
        if final {
            // One digit left over cannot stand for a byte: the text was cut off or damaged.
            if sextets.count == 1 { report("the Base64 text ends in the middle of a group") }
            if strayCharacters > 0 { report("\(strayCharacters) characters that are not Base64 were skipped") }
            sextets = []
        }
        if length > 0 { try sink.write(Array(bytes[0..<length])) }
    }

    /// A value of a header line: `name="x"` or `name=x`.
    private func parameter(_ key: String, in line: String) -> String? {
        guard let range = line.range(of: key + "=", options: .caseInsensitive) else { return nil }
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
        return rest.split(whereSeparator: { $0 == ";" || $0 == " " }).first.map(String.init)
    }

    /// The value of ` key=` in a yEnc line (up to the next space).
    private func yParameter(_ key: String, in line: String) -> String? {
        guard let range = line.range(of: " " + key + "=") else { return nil }
        return line[range.upperBound...].split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init)
    }

    /// `sum -r/size 12345/450`.
    private func trailer(_ line: ArraySlice<UInt8>) -> (sum: UInt32, size: Int64)? {
        let prefix = Array("sum -r/size ".utf8)
        guard line.starts(with: prefix) else { return nil }
        let numbers = text(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces).split(separator: "/")
        guard numbers.count == 2, let sum = UInt32(numbers[0]), let size = Int64(numbers[1]) else { return nil }
        return (sum, size)
    }

    private func check(_ pending: SixBitTally, against trailer: (sum: UInt32, size: Int64)?) {
        awaitingTrailer = nil
        let name = pending.name ?? "(no name)"
        if let trailer {
            if trailer.size != pending.size {
                problems.append(
                    "\(name): \(pending.size) bytes were decoded, but the text says \(trailer.size): lines are missing or damaged"
                )
            } else if trailer.sum != pending.sum {
                problems.append("\(name): the checksum (sum -r) does not match: the data is damaged")
            }
        } else if pending.skippedLines > 0 || pending.shortLinesInside > 0 {
            problems.append(
                "\(name): \(pending.skippedLines + pending.shortLinesInside) lines could not be read or are out of place and nothing confirms the size"
            )
        }
    }

    /// Looks at the line after `end`: the `sum -r/size` line that checks the file, if there is one.
    ///
    /// Returns true when the line was that one.
    private func resolveTrailer(with line: ArraySlice<UInt8>) -> Bool {
        guard let pending = awaitingTrailer, !line.isEmpty else { return false }
        if let found = trailer(line) {
            check(pending, against: found)
            return true
        }
        check(pending, against: nil)
        return false
    }

    func feed(_ line: ArraySlice<UInt8>) throws {
        if awaitingTrailer != nil, case .searching = state, resolveTrailer(with: line) { return }
        switch state {
        case .searching:
            guard !line.isEmpty else { return }
            defer { sawText = true }
            if line.starts(with: Array("begin-base64 ".utf8)) {
                let fields = text(line).split(separator: " ", maxSplits: 2).map(String.init)
                try open(fields.count == 3 ? fields[2] : nil, .base64(endsAtMark: true, mime: false))
            } else if line.starts(with: Array("begin ".utf8)) {
                let fields = text(line).split(separator: " ", maxSplits: 2).map(String.init)
                guard fields.count >= 2, fields[1].allSatisfy({ ("0"..."7").contains($0) }) else { return }
                try open(fields.count == 3 ? fields[2] : nil, .sixBit(xx: nil))
            } else if line.starts(with: Array("=ybegin ".utf8)) {
                let header = text(line)
                try open(header.range(of: " name=").map { String(header[$0.upperBound...]) }, .yEnc)
                yHeaderSize = yParameter("size", in: header).flatMap { Int64($0) }
            } else if case let lowered = text(line.prefix(40)).lowercased(),
                lowered.hasPrefix("mime-version:") || lowered.hasPrefix("content-")
            {
                state = .mimeHeaders(name: nil, isBase64: false)
                try feed(line)
            } else if !sawText, filesDecoded == 0,
                line.allSatisfy({ Self.base64Values[Int($0)] != 255 || $0 == UInt8(ascii: "=") })
            {
                // Nothing but Base64 from the first line on: the output of `base64`.
                try open(nil, .base64(endsAtMark: false, mime: false))
                try feed(line)
            }

        case .mimeHeaders(var name, var isBase64):
            if line.isEmpty {
                if isBase64 { try open(name, .base64(endsAtMark: false, mime: true)) } else { state = .searching }
                return
            }
            let header = text(line)
            if header.lowercased().hasPrefix("content-transfer-encoding:") {
                isBase64 = header.lowercased().contains("base64")
            }
            name = parameter("filename", in: header) ?? name ?? parameter("name", in: header)
            state = .mimeHeaders(name: name, isBase64: isBase64)

        case .base64(let endsAtMark, let mime):
            // A boundary of the mail, or the end mark of `uuencode -m`.
            if endsAtMark, line.starts(with: Array("====".utf8)) {
                sawEndMark = true
                try close()
                return
            }
            // `-` is a digit of the URL-safe alphabet: outside a mail a line starting with `--` is
            // a boundary only when it is not Base64 (a file that starts with "----" is data).
            if line.starts(with: [45, 45]), mime || Self.looksLikeBoundary(line) {
                try close()
                return
            }
            // The next file or mail part starts here, with or without a boundary in between.
            if Self.startsNewFile(line) {
                try close()
                try feed(line)
                return
            }
            // The padding is the end of the data.
            var padded = false
            var stray = 0
            sextets.reserveCapacity(sextets.count + line.count)
            Self.base64Values.withUnsafeBufferPointer { table in
                for character in line {
                    let value = table[Int(character)]
                    if value != 255 {
                        sextets.append(value)
                    } else if character == UInt8(ascii: "=") {
                        padded = true
                        break
                    } else if character != 32, character != 9 {
                        stray += 1
                    }
                }
            }
            strayCharacters += stray
            if !line.isEmpty {
                if bodyLines == 0 { firstLineLength = line.count }
                bodyLines += 1
                lastLineLength = line.count
            }
            if padded {
                try close()
                return
            }
            if sextets.count >= 4_096 { try flushBase64(final: false) }

        case .sixBit(var xx):
            if line.elementsEqual(Array("end".utf8)) {
                let finished = tally
                try close()
                awaitingTrailer = finished
                return
            }
            guard !line.isEmpty else { return }
            if xx == nil {
                // A line that fits UUEncode exactly is UUEncode; XXEncode has no character below `+`.
                let asUU = SixBitText.decode(line, xx: false)
                let asXX = SixBitText.decode(line, xx: true)
                let fitsUU = asUU.map { line.count - 1 == ($0.count + 2) / 3 * 4 } == true
                xx = fitsUU ? false : asXX != nil ? true : asUU != nil ? false : nil
                state = .sixBit(xx: xx)
            }
            // What is not a line of the format (a mail's own lines between parts) is passed over,
            // and counted: it is harmless when the size at the end agrees, damage when not.
            guard let xx, let bytes = SixBitText.decode(line, xx: xx) else {
                tally.skippedLines += 1
                return
            }
            guard !bytes.isEmpty else { return }
            // Only the last line of a file is shorter than the others.
            if let last = tally.lastCount, let full = tally.fullCount, last < full { tally.shortLinesInside += 1 }
            tally.lastCount = bytes.count
            tally.fullCount = tally.fullCount ?? bytes.count
            tally.size += Int64(bytes.count)
            // The checksum of Unix `sum -r`: a 16-bit sum that is rotated before every byte.
            var sum = tally.sum
            for byte in bytes { sum = ((sum >> 1) + ((sum & 1) << 15) + UInt32(byte)) & 0xFFFF }
            tally.sum = sum
            try sink.write(bytes)

        case .yEnc:
            if line.starts(with: Array("=yend".utf8)) {
                checkYEnd(text(line))
                try close()
                return
            }
            if line.starts(with: Array("=ypart".utf8)) {
                let header = text(line)
                yHasPart = true
                // The two numbers are whatever the text says. A part begins at byte 1 or later
                // and ends at or after its beginning; only then is its length a number that can
                // be worked out (`end - begin` of numbers from anywhere overflows). Anything
                // else is a damaged header, and is said to be one.
                let (beginText, endText) = (yParameter("begin", in: header), yParameter("end", in: header))
                if let begin = beginText.flatMap({ Int64($0) }), let end = endText.flatMap({ Int64($0) }), begin >= 1,
                    end >= begin
                {
                    yPartLength = (end - begin).addingSaturated(1)
                } else if beginText != nil || endText != nil {
                    yPartLength = nil
                    report("the range of the part (=ypart begin= end=) is not valid: the text is damaged")
                }
                return
            }
            if line.starts(with: Array("=ybegin".utf8)) { return }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(line.count)
            var escaped = false
            for character in line {
                if escaped {
                    bytes.append(character &- 64 &- 42)
                    escaped = false
                } else if character == UInt8(ascii: "=") {
                    escaped = true
                } else {
                    bytes.append(character &- 42)
                }
            }
            if !bytes.isEmpty {
                yBytes += Int64(bytes.count)
                yCRC.update(Data(bytes))
                try sink.write(bytes)
            }
        }
    }

    /// A line that starts with `--` and cannot be Base64 (after the padding it may end in): a boundary.
    private static func looksLikeBoundary(_ line: ArraySlice<UInt8>) -> Bool {
        var body = line
        while body.last == UInt8(ascii: "="), line.count - body.count < 2 { body = body.dropLast() }
        return body.contains { base64Values[Int($0)] == 255 }
    }

    /// `=yend size=N [part=P] [pcrc32=X] [crc32=X]`: compares the size and the CRC32 with what was decoded.
    private func checkYEnd(_ line: String) {
        if let size = yParameter("size", in: line).flatMap({ Int64($0) }), size != yBytes {
            report("\(yBytes) bytes were decoded, but =yend says \(size): the text is incomplete or damaged")
        } else if yHasPart, let length = yPartLength, length != yBytes {
            report("\(yBytes) bytes were decoded, but the part holds \(length): the text is incomplete or damaged")
        } else if !yHasPart, let total = yHeaderSize, total != yBytes {
            report("\(yBytes) bytes were decoded, but =ybegin says \(total): the text is incomplete or damaged")
        }
        // A part carries the CRC32 of the part; a single file has only crc32.
        let crcText =
            yHasPart
            ? yParameter("pcrc32", in: line) : (yParameter("crc32", in: line) ?? yParameter("pcrc32", in: line))
        if let crcText, let expected = UInt32(crcText.trimmingCharacters(in: .whitespaces), radix: 16),
            expected != yCRC.checksum
        {
            report("the CRC32 does not match: the data is damaged")
        }
    }
}

/// Decode File (spec 08 › Decode).
enum Decoder {
    /// Cuts blocks of a file into lines.
    ///
    /// A line longer than this is handed on in pieces (the output of `base64` is one line as long
    /// as the file).
    private struct LineCutter {
        static let longestLine = 1 << 16
        private var pending: [UInt8] = []

        mutating func cut(_ block: Data, _ body: (ArraySlice<UInt8>) throws -> Void) rethrows {
            pending.append(contentsOf: block)
            var start = 0
            while let end = pending[start...].firstIndex(of: 10) {
                var line = pending[start..<end]
                if line.last == 13 { line = line.dropLast() }
                try body(line)
                start = end + 1
            }
            while pending.count - start >= Self.longestLine {
                try body(pending[start..<(start + Self.longestLine)])
                start += Self.longestLine
            }
            pending.removeFirst(start)
        }

        mutating func flush(_ body: (ArraySlice<UInt8>) throws -> Void) rethrows {
            var line = pending[pending.indices]
            if line.last == 13 { line = line.dropLast() }
            if !line.isEmpty { try body(line) }
            pending = []
        }
    }

    /// Writes the decoded files into a folder.
    private final class FolderSink: DecodeSink {
        let directory: URL
        let fallbackName: String
        let autoRename: Bool
        let run: ToolRun
        var output: ToolOutput?
        var written: [URL] = []
        private var pending = Data()

        init(directory: URL, fallbackName: String, autoRename: Bool, run: ToolRun) {
            self.directory = directory
            self.fallbackName = fallbackName
            self.autoRename = autoRename
            self.run = run
        }

        func begin(name: String?) throws {
            // The name is a name: whatever the text says, the file lands in the target folder.
            // `appending(safeName:)` is the last word: one name, no `/` or NUL byte, never `.` or `..`.
            guard
                let url = Decoder.safeName(name).flatMap({ directory.appending(safeName: $0) })
                    ?? directory.appending(safeName: fallbackName)
            else {
                throw ToolError.failed("The decoded file has no usable name.")
            }
            run.show(["To: " + run.fileSystems.displayPath(url)])
            // A file the user skips is decoded into nothing.
            output = try run.create(url, autoRename: autoRename, deferred: true)
        }

        func write(_ bytes: [UInt8]) throws {
            guard output != nil else { return }
            pending.append(contentsOf: bytes)
            if pending.count >= ToolRun.blockSize { try flush() }
        }

        private func flush() throws {
            try output?.write(pending)
            pending.removeAll(keepingCapacity: true)
        }

        func end() throws {
            try flush()
            try output?.finish()
            if let output { written.append(output.url) }
            output = nil
        }
    }

    /// The name from the encoded data as a file name: without a path, and with the characters
    /// a name cannot have replaced by `_`.
    ///
    /// The path is cut on the code points (a `/` followed by a combining mark is one character to
    /// Swift, but a slash to the file system).
    static func safeName(_ name: String?, replacingColon: Bool = true) -> String? {
        guard let scalars = name?.unicodeScalars else { return nil }
        let last = scalars.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last
        guard let last else { return nil }
        var cleaned = String.UnicodeScalarView()
        for scalar in last {
            cleaned.append(scalar.value < 32 || scalar.value == 127 || (replacingColon && scalar == ":") ? "_" : scalar)
        }
        let result = String(cleaned).trimmingCharacters(in: .whitespaces)
        // A name longer than the file system takes is cut at a code point, not refused.
        let name = result.utf8.count > 255 ? trimmedToLimit(result) : result
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        return name
    }

    /// The longest start of `name` that takes at most 255 bytes, cut at a code point.
    ///
    /// Called for names longer than that, so it is never empty, `.` or `..`.
    private static func trimmedToLimit(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        var bytes = 0
        for scalar in name.unicodeScalars {
            let width = String(scalar).utf8.count
            if bytes + width > 255 { break }
            scalars.append(scalar)
            bytes += width
        }
        return String(scalars)
    }

    /// The name of the decoded file when the data gives none: the encoded file's without its extension.
    static func fallbackName(for encodedName: String) -> String {
        let base = FileItem.split(encodedName).base
        return base == encodedName ? encodedName + ".decoded" : base
    }

    /// Whether the first line of a numbered neighbour starts an encoded file of its own
    /// (`IMG_0002.b64` next to `IMG_0001.b64`): the parts the encoder writes carry the header
    /// in the first one only.
    private static func startsFreshFile(_ part: FileItem, run: ToolRun) -> Bool {
        guard let reader = try? run.openReader(part.url) else { return false }
        defer { reader.close() }
        let token = run.cancellation.interrupting(reader)
        defer { withExtendedLifetime(token) {} }
        guard let head = try? reader.read(upToCount: 4_096) else { return false }
        for var line in head.split(separator: 10, omittingEmptySubsequences: true) {
            if line.last == 13 { line = line.dropLast() }
            if line.isEmpty { continue }
            return DecodeMachine.startsNewFile(ArraySlice(line))
        }
        return false
    }

    /// What a decode made: the files, and what is wrong with them (see `DecodeMachine.problems`).
    struct Outcome: Equatable {
        var files: [URL]
        var problems: [String]
    }

    /// Decodes the file and, while a file inside it is unfinished, the parts that follow it by
    /// their counter (`file001.uue`, `file002.uue`, …).
    ///
    /// Returns the files written.
    @discardableResult
    static func decode(_ first: FileItem, into directory: URL, autoRename: Bool = false, run: ToolRun) throws -> [URL] {
        try decodeChecked(first, into: directory, autoRename: autoRename, run: run).files
    }

    /// Like `decode`, and says what is incomplete or damaged: the files are kept all the same.
    static func decodeChecked(_ first: FileItem, into directory: URL, autoRename: Bool = false, run: ToolRun) throws
        -> Outcome
    {
        let provider = try run.provider(for: first.url)
        run.carriesOrigin = true
        let sink = FolderSink(
            directory: directory,
            fallbackName: fallbackName(for: first.name),
            autoRename: autoRename,
            run: run
        )
        let machine = DecodeMachine(sink: sink)
        let candidates = PartSeries.parts(startingAt: first, provider: provider, cancellation: run.cancellation)
        run.expect(bytes: first.size, items: 0)
        let files: [URL] = try run.transaction {
            for (index, part) in candidates.enumerated() {
                // Further parts are read only while a file is open, and counted when their turn comes.
                if index > 0 {
                    guard machine.needsMoreParts, !startsFreshFile(part, run: run) else { break }
                    run.expect(bytes: candidates.prefix(index + 1).reduce(0) { $0.addingSaturated($1.size) }, items: 0)
                }
                var cutter = LineCutter()
                try run.read(part.url) { block in try cutter.cut(block, machine.feed) }
                try cutter.flush(machine.feed)
            }
            try machine.finish()
            return sink.written
        }
        guard machine.filesDecoded > 0 else {
            throw ToolError.failed("\(first.name) holds no encoded file (MIME/Base64, UUEncode, XXEncode, yEnc).")
        }
        return Outcome(files: files, problems: machine.problems)
    }
}
