import AFMKernel
import Foundation

/// Split File (spec 08 › Split file).
internal enum Splitter {
    /// The parts of one split, written one after another, and the CRC32 of the whole.
    private final class PartWriter {
        /// The file that is split.
        let source: URL
        /// The folder the parts go into.
        let directory: URL
        /// The name of the parts without their numbers.
        let base: String
        /// The size of every part but the last.
        let partSize: Int64
        /// The run the parts are written in.
        let run: ToolRun
        /// The CRC32 of what was read.
        let crc = CRC32Hasher()
        /// The bytes read.
        var total: Int64 = 0
        /// The parts made so far.
        var written: [URL]
        /// The part being written.
        var output: ToolOutput

        /// Starts the first part.
        init(source: URL, directory: URL, base: String, partSize: Int64, run: ToolRun) throws {
            self.source = source
            self.directory = directory
            self.base = base
            self.partSize = partSize
            self.run = run
            output = try Splitter.open(part: 1, of: source, in: directory, base: base, run: run)
            written = [output.url]
        }

        /// Writes a block of the source across as many parts as it takes.
        func write(_ block: Data) throws {
            crc.update(block)
            total += Int64(block.count)
            var offset = 0
            while offset < block.count {
                if output.bytesWritten == partSize {
                    try output.finish()
                    guard written.count < maximumParts else {
                        throw ToolError.failed("More than \(maximumParts) parts.")
                    }
                    output = try Splitter.open(part: written.count + 1, of: source, in: directory, base: base, run: run)
                    written.append(output.url)
                }
                let room = Int(min(partSize - output.bytesWritten, Int64(block.count - offset)))
                try output.write(block.subdata(in: (block.startIndex + offset)..<(block.startIndex + offset + room)))
                offset += room
            }
        }

        /// Finishes the last part and writes the `.crc` file of the whole; returns every file written.
        func finish(name: String) throws -> [URL] {
            try output.finish()
            let info = SplitInfo(name: name, size: total, crc: crc.checksum)
            guard
                let crcFile = try run.write(
                    Data(info.text.utf8),
                    to: directory.appending(name: base + ".crc"),
                    deferred: true
                )
            else {
                throw ToolError.cancelled
            }
            return written + [crcFile]
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The sizes of the "Bytes per file" list. 360 k is the usable capacity of the floppy as
    /// the spec records it; the other floppy sizes follow the same rule, the larger media
    /// are taken at their nominal size.
    internal static let presets: [(title: String, bytes: Int64)] = [
        ("Automatic", 1_457_664), ("1.44 MB (3.5\")", 1_457_664), ("1.2 MB (5.25\")", 1_213_952),
        ("720 k (3.5\")", 730_112),
        ("360 k (5.25\")", 362_496), ("100 MB (ZIP)", 100 << 20), ("250 MB (ZIP)", 250 << 20),
        ("650 MB (CD-R)", 650 << 20),
        ("700 MB (CD-R)", 700 << 20)
    ]
    /// The most parts a file is split into (the counter has three digits).
    internal static let maximumParts = 999

    /// Reads a typed size: bytes, or a number with `k`, `M` or `G` (1 k = 1024 bytes), or the
    /// caption of a preset.
    internal static func size(from text: String) -> Int64? {
        let typed = text.trimmingCharacters(in: .whitespaces)
        if let preset = presets.first(where: { preset in preset.title.caseInsensitiveCompare(typed) == .orderedSame }) {
            return preset.bytes
        }
        var digits = typed.replacingOccurrences(of: ",", with: "").lowercased()
        if digits.hasSuffix("b"), digits.count > 1, digits.dropLast().last?.isNumber != true {
            digits.removeLast()
        }
        var factor = 1.0
        if let unit = digits.last, let shift = ["k": 10.0, "m": 20.0, "g": 30.0][unit] {
            factor = pow(2, shift)
            digits.removeLast()
        }
        guard let number = Double(digits.trimmingCharacters(in: .whitespaces)), number > 0, number * factor < 9e18
        else {
            return nil
        }
        let bytes = Int64((number * factor).rounded())
        return bytes > 0 ? bytes : nil
    }

    /// The name of part `number`: `<base>.001`, `<base>.002`, ….
    internal static func partName(_ base: String, _ number: Int) -> String {
        base + String(format: ".%03d", number)
    }

    /// Writes `<base>.001`, `<base>.002`, … and `<base>.crc` into `directory`.
    ///
    /// Returns the files written. On failure or cancel nothing of them is left, and a file that was
    /// there before is never touched: parts that replace one are written aside and take its place
    /// only when all are done.
    @discardableResult
    internal static func split(_ source: FileItem, into directory: URL, partSize: Int64, run: ToolRun) throws -> [URL] {
        guard partSize > 0 else {
            throw ToolError.failed("The size of the parts is not valid.")
        }
        run.carriesOrigin = true
        // (A size typed by the user, or one a server says: neither may overflow the sum.)
        guard source.size.addingSaturated(partSize - 1) / partSize <= Int64(maximumParts) else {
            throw ToolError.failed("With this size the file would be split into more than \(maximumParts) parts.")
        }
        let base = FileItem.split(source.name).base
        // No output may be the source itself (splitting `data.001` in place): it would be replaced.
        let parts = max(1, Int(source.size.addingSaturated(partSize - 1) / partSize))
        let outputs =
            (1...parts).map { number in directory.appending(name: partName(base, number)) }
            + [directory.appending(name: base + ".crc")]
        guard !outputs.contains(where: { output in ToolRun.isSameFile(output, source.url) }) else {
            throw ToolError.failed("A part of \(source.name) would replace the file itself.")
        }
        // The source is opened before anything is created.
        let reader = try run.openReader(source.url)
        var readerIsOpen = true
        defer {
            if readerIsOpen {
                reader.close()
            }
        }
        run.expect(bytes: source.size, items: 0)
        return try run.transaction {
            let writer = try PartWriter(
                source: source.url,
                directory: directory,
                base: base,
                partSize: partSize,
                run: run
            )
            readerIsOpen = false
            try run.read(reader, counted: true, blockSize: ToolRun.blockSize) { block in try writer.write(block) }
            return try writer.finish(name: source.name)
        }
    }

    /// Creates part `number` of the split of `source`, saying so in the progress window.
    private static func open(part number: Int, of source: URL, in directory: URL, base: String, run: ToolRun) throws
        -> ToolOutput
    {
        let url = directory.appending(name: partName(base, number))
        run.show(["From: " + run.fileSystems.displayPath(source), "To: " + run.fileSystems.displayPath(url)])
        guard let part = try run.create(url, autoRename: false, deferred: true) else {
            throw ToolError.cancelled
        }
        return part
    }
}
