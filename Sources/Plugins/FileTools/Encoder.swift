import AFMKernel
import Foundation

/// Encode File (spec 08 › Encode, Encoded output format).
internal enum Encoder {
    /// How a file is encoded: the format, and how much of it one file holds at most.
    internal struct Options: Equatable {
        /// The format.
        internal var method: EncodeMethod
        /// The most lines of text one file holds; 0 for no limit.
        internal var linesPerFile = 0
        /// The most bytes of text (without the header) one file holds; 0 for no limit.
        internal var bytesPerFile: Int64 = 0
    }

    /// The encoded files of one source, written one after another under the planned names.
    private final class EncodedParts {
        /// The file that is encoded.
        let source: FileItem
        /// The folder the files go into.
        let directory: URL
        /// The names of the files, in order.
        let names: [String]
        /// The most bytes of text one file takes; nil for no limit.
        let capacity: Int?
        /// The run the files are written in.
        let run: ToolRun
        /// The files made so far.
        var written: [URL] = []
        /// The file being written.
        var output: ToolOutput
        /// The encoded bytes in the current file, without the header.
        var bodyBytes = 0

        /// Starts the first file.
        init(source: FileItem, directory: URL, names: [String], capacity: Int?, run: ToolRun) throws {
            self.source = source
            self.directory = directory
            self.names = names
            self.capacity = capacity
            self.run = run
            output = try Encoder.open(names[0], of: source.url, in: directory, run: run)
            written = [output.url]
        }

        /// Writes whole lines, going on to the next file where the limit is reached.
        func write(_ text: Data) throws {
            var offset = 0
            let room = capacity ?? Int.max
            while offset < text.count {
                if capacity != nil, bodyBytes == room {
                    try output.finish()
                    // The source may have grown since the panel listed it; more parts than names are not made up.
                    guard written.count < names.count else {
                        throw ToolError.failed(
                            "\(source.name) changed while it was encoded (it needs more parts than planned)."
                        )
                    }
                    output = try Encoder.open(names[written.count], of: source.url, in: directory, run: run)
                    written.append(output.url)
                    bodyBytes = 0
                }
                let chunk = min(room - bodyBytes, text.count - offset)
                try output.write(text.subdata(in: (text.startIndex + offset)..<(text.startIndex + offset + chunk)))
                bodyBytes += chunk
                offset += chunk
            }
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The names of the encoded files: one file keeps the base name, several are numbered
    /// `name001.uue`, `name002.uue`, … which is what Decode looks for.
    internal static func outputNames(for name: String, method: EncodeMethod, parts: Int) -> [String] {
        let base = FileItem.split(name).base
        guard parts > 1 else {
            return [base + "." + method.fileExtension]
        }
        return (1...parts).map { number in base + String(format: "%03d", number) + "." + method.fileExtension }
    }

    /// How many lines go into one file: the smaller of the two limits, 0 for no limit.
    ///
    /// "Bytes per file" counts the encoded text without the header.
    internal static func linesPerFile(lines: Int, bytes: Int64, method: EncodeMethod) -> Int {
        let fromBytes = bytes > 0 ? max(1, Int(min(bytes / Int64(method.lineLength), Int64(Int32.max)))) : 0
        if lines > 0, fromBytes > 0 {
            return min(lines, fromBytes)
        }
        return max(lines, fromBytes)
    }

    /// What an encoded file starts with: the mail headers of MIME, or the `begin` line of the other two.
    internal static func header(for name: String, method: EncodeMethod) -> String {
        switch method {
        case .mime:
            let quoted = name.replacingOccurrences(of: "\"", with: "_")
            return "MIME-Version: 1.0\r\nContent-Type: application/octet-stream; name=\"\(quoted)\"\r\n"
                + "Content-Transfer-Encoding: base64\r\n"
                + "Content-Disposition: attachment; filename=\"\(quoted)\"\r\n\r\n"

        case .uue, .xxe:
            return "begin 644 \(name)\r\n"
        }
    }

    /// Encodes `source` into `directory` and returns the files written; on failure or cancel
    /// none of them is left, and a file that was there before is never touched (see `Splitter.split`).
    @discardableResult
    internal static func encode(_ source: FileItem, into directory: URL, options: Options, run: ToolRun) throws
        -> [URL]
    {
        run.carriesOrigin = true
        let method = options.method
        let limit = Self.linesPerFile(lines: options.linesPerFile, bytes: options.bytesPerFile, method: method)
        let names = try names(of: source, into: directory, method: method, limit: limit)
        // The source is opened before anything is created.
        let reader = try run.openReader(source.url)
        var readerIsOpen = true
        defer {
            if readerIsOpen {
                reader.close()
            }
        }
        run.expect(bytes: source.size, items: 0)
        // The most bytes of text one file takes; a huge limit is no limit.
        let (capacity, overflows) = limit.multipliedReportingOverflow(by: method.lineLength)
        return try run.transaction {
            let parts = try EncodedParts(
                source: source,
                directory: directory,
                names: names,
                capacity: limit > 0 && !overflows ? capacity : nil,
                run: run
            )
            readerIsOpen = false
            try parts.output.write(Data(header(for: source.name, method: method).utf8))
            let (checksum, size) = try encodeBody(of: reader, method: method, into: parts, run: run)
            switch method {
            case .mime:
                break

            case .uue:
                try parts.output.write(Data("`\r\nend\r\nsum -r/size \(checksum)/\(size)\r\n".utf8))

            case .xxe:
                try parts.output.write(Data("+\r\nend\r\nsum -r/size \(checksum)/\(size)\r\n".utf8))
            }
            try parts.output.finish()
            return parts.written
        }
    }

    /// The names of the encoded files of `source`, with `limit` lines each (0 for no limit); throws when there
    /// would be more than 999, or one would be the source itself.
    private static func names(of source: FileItem, into directory: URL, method: EncodeMethod, limit: Int) throws
        -> [String]
    {
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
        guard !names.contains(where: { name in ToolRun.isSameFile(directory.appending(name: name), source.url) }) else {
            throw ToolError.failed("The encoded file would replace \(source.name) itself.")
        }
        return names
    }

    /// Encodes what `reader` reads, whole lines at a time, into the parts; returns the `sum -r` checksum and the
    /// size of the source.
    private static func encodeBody(
        of reader: any FileReader,
        method: EncodeMethod,
        into parts: EncodedParts,
        run: ToolRun
    ) throws -> (checksum: UInt32, size: Int64) {
        var checksum: UInt32 = 0
        var size: Int64 = 0
        var carry = Data()
        try run.read(reader, counted: true, blockSize: ToolRun.blockSize) { block in
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
            guard whole > 0 else {
                return
            }
            try parts.write(encoded(carry.prefix(whole), method: method))
            carry = Data(carry.dropFirst(whole))
        }
        if !carry.isEmpty {
            try parts.write(encoded(carry, method: method))
        }
        return (checksum, size)
    }

    /// The text of whole lines of the source in the method's format.
    private static func encoded(_ data: Data, method: EncodeMethod) -> Data {
        switch method {
        case .mime:
            return data.base64EncodedData(options: [
                .lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed
            ]) + Data([13, 10])

        case .uue, .xxe:
            return SixBitText.encode(data, xxEncode: method == .xxe)
        }
    }

    /// Creates the encoded file `name`, saying so in the progress window.
    private static func open(_ name: String, of source: URL, in directory: URL, run: ToolRun) throws -> ToolOutput {
        let url = directory.appending(name: name)
        run.show(["From: " + run.fileSystems.displayPath(source), "To: " + run.fileSystems.displayPath(url)])
        guard let part = try run.create(url, autoRename: false, deferred: true) else {
            throw ToolError.cancelled
        }
        return part
    }
}
