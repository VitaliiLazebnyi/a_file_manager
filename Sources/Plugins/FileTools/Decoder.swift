import AFMKernel
import Foundation

/// Decode File (spec 08 › Decode).
internal enum Decoder {
    /// Cuts blocks of a file into lines.
    ///
    /// A line longer than this is handed on in pieces (the output of `base64` is one line as long
    /// as the file).
    private struct LineCutter {
        /// The longest piece of a line handed on at once.
        static let longestLine = 1 << 16
        /// What came after the last line break.
        private var pending: [UInt8] = []

        /// Hands the lines `block` completes to `body`, without their line breaks.
        mutating func cut(_ block: Data, _ body: (ArraySlice<UInt8>) throws -> Void) rethrows {
            pending.append(contentsOf: block)
            var start = 0
            while let end = pending[start...].firstIndex(of: 10) {
                var line = pending[start..<end]
                if line.last == 13 {
                    line = line.dropLast()
                }
                try body(line)
                start = end + 1
            }
            while pending.count - start >= Self.longestLine {
                try body(pending[start..<(start + Self.longestLine)])
                start += Self.longestLine
            }
            pending.removeFirst(start)
        }

        /// Hands the last line, which ended without a line break, to `body`.
        mutating func flush(_ body: (ArraySlice<UInt8>) throws -> Void) rethrows {
            var line = pending[pending.indices]
            if line.last == 13 {
                line = line.dropLast()
            }
            if !line.isEmpty {
                try body(line)
            }
            pending = []
        }
    }

    /// Writes the decoded files into a folder.
    private final class FolderSink: DecodeSink {
        /// The folder the files go into.
        let directory: URL
        /// The name of a file whose text gives none.
        let fallbackName: String
        /// Whether a file in the way makes the new one take a free name instead of asking.
        let autoRename: Bool
        /// The run the files are written in.
        let run: ToolRun
        /// The file being written; nil while none is, or when the user skipped it.
        var output: ToolOutput?
        /// The files written.
        var written: [URL] = []
        /// Decoded bytes not written yet.
        private var pending = Data()

        /// A sink into `directory`.
        init(directory: URL, fallbackName: String, autoRename: Bool, run: ToolRun) {
            self.directory = directory
            self.fallbackName = fallbackName
            self.autoRename = autoRename
            self.run = run
        }

        /// Creates the file of that name in the folder, whatever the text says the name is.
        func begin(name: String?) throws {
            // The name is a name: whatever the text says, the file lands in the target folder.
            // `appending(safeName:)` is the last word: one name, no `/` or NUL byte, never `.` or `..`.
            guard
                let url = Decoder.safeName(name, replacingColon: true)
                    .flatMap({ safe in directory.appending(safeName: safe) })
                    ?? directory.appending(safeName: fallbackName)
            else {
                throw ToolError.failed("The decoded file has no usable name.")
            }
            run.show(["To: " + run.fileSystems.displayPath(url)])
            // A file the user skips is decoded into nothing.
            output = try run.create(url, autoRename: autoRename, deferred: true)
        }

        /// Collects decoded bytes and writes them a block at a time.
        func write(_ bytes: [UInt8]) throws {
            guard output != nil else {
                return
            }
            pending.append(contentsOf: bytes)
            if pending.count >= ToolRun.blockSize {
                try flush()
            }
        }

        /// Writes what was collected.
        private func flush() throws {
            try output?.write(pending)
            pending.removeAll(keepingCapacity: true)
        }

        /// Finishes the file.
        func end() throws {
            try flush()
            try output?.finish()
            if let output {
                written.append(output.url)
            }
            output = nil
        }

        deinit {
            // Nothing to release.
        }
    }

    /// What a decode made: the files, and what is wrong with them (see `DecodeMachine.problems`).
    internal struct Outcome: Equatable {
        /// The files written.
        internal var files: [URL]
        /// What is incomplete or damaged in them.
        internal var problems: [String]
    }

    /// The name from the encoded data as a file name: without a path, and with the characters
    /// a name cannot have replaced by `_` (with `replacingColon` also `:`).
    ///
    /// The path is cut on the code points (a `/` followed by a combining mark is one character to
    /// Swift, but a slash to the file system).
    internal static func safeName(_ name: String?, replacingColon: Bool) -> String? {
        guard let scalars = name?.unicodeScalars else {
            return nil
        }
        let last = scalars.split { scalar in scalar == "/" || scalar == "\\" }.last
        guard let last else {
            return nil
        }
        var cleaned = String.UnicodeScalarView()
        for scalar in last {
            cleaned.append(scalar.value < 32 || scalar.value == 127 || (replacingColon && scalar == ":") ? "_" : scalar)
        }
        let result = String(cleaned).trimmingCharacters(in: .whitespaces)
        // A name longer than the file system takes is cut at a code point, not refused.
        let limited = result.utf8.count > 255 ? trimmedToLimit(result) : result
        guard !limited.isEmpty, limited != ".", limited != ".." else {
            return nil
        }
        return limited
    }

    /// The longest start of `name` that takes at most 255 bytes, cut at a code point.
    ///
    /// Called for names longer than that, so it is never empty, `.` or `..`.
    private static func trimmedToLimit(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        var bytes = 0
        for scalar in name.unicodeScalars {
            let width = String(scalar).utf8.count
            if bytes + width > 255 {
                break
            }
            scalars.append(scalar)
            bytes += width
        }
        return String(scalars)
    }

    /// The name of the decoded file when the data gives none: the encoded file's without its extension.
    internal static func fallbackName(for encodedName: String) -> String {
        let base = FileItem.split(encodedName).base
        return base == encodedName ? encodedName + ".decoded" : base
    }

    /// Whether the first line of a numbered neighbour starts an encoded file of its own
    /// (`IMG_0002.b64` next to `IMG_0001.b64`): the parts the encoder writes carry the header
    /// in the first one only.
    private static func startsFreshFile(_ part: FileItem, run: ToolRun) -> Bool {
        guard let reader = try? run.openReader(part.url) else {
            return false
        }
        defer { reader.close() }
        let token = run.cancellation.interrupting(reader)
        defer {
            withExtendedLifetime(token) {
                // The reader can be interrupted up to here.
            }
        }
        guard let head = try? reader.read(upToCount: 4_096) else {
            return false
        }
        for var line in head.split(separator: 10, omittingEmptySubsequences: true) {
            if line.last == 13 {
                line = line.dropLast()
            }
            if line.isEmpty {
                continue
            }
            return DecodeMachine.startsNewFile(ArraySlice(line))
        }
        return false
    }

    /// Decodes the file and, while a file inside it is unfinished, the parts that follow it by
    /// their counter (`file001.uue`, `file002.uue`, …); with `autoRename` a file in the way makes a new one take
    /// a free name.
    ///
    /// Returns the files written.
    @discardableResult
    internal static func decode(_ first: FileItem, into directory: URL, autoRename: Bool, run: ToolRun) throws
        -> [URL]
    {
        try decodeChecked(first, into: directory, autoRename: autoRename, run: run).files
    }

    /// Like `decode`, and says what is incomplete or damaged: the files are kept all the same.
    internal static func decodeChecked(_ first: FileItem, into directory: URL, autoRename: Bool, run: ToolRun) throws
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
                    guard machine.needsMoreParts, !startsFreshFile(part, run: run) else {
                        break
                    }
                    let bytes = candidates.prefix(index + 1)
                        .reduce(Int64(0)) { total, item in total.addingSaturated(item.size) }
                    run.expect(bytes: bytes, items: 0)
                }
                var cutter = LineCutter()
                try run.read(part.url, counted: true, blockSize: ToolRun.blockSize) { block in
                    try cutter.cut(block, machine.feed)
                }
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
