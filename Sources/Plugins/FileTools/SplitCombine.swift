import AFMKernel
import Foundation

/// The `.crc` file Split writes next to the parts (spec 08 › The `.crc` file): the original
/// name, size and CRC32 in three lines that end in CRLF.
struct SplitInfo: Equatable {
    var name: String
    var size: Int64
    var crc: UInt32

    var text: String {
        "filename=\(name)\r\nsize=\(size)\r\ncrc32=\(String(format: "%08X", crc))\r\n"
    }

    init(name: String, size: Int64, crc: UInt32) {
        self.name = name
        self.size = size
        self.crc = crc
    }

    /// Nil when a line is missing or unreadable.
    init?(text: String) {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            values[line[..<equals].lowercased()] = String(line[line.index(after: equals)...])
        }
        guard let name = values["filename"], !name.isEmpty, let size = values["size"].flatMap({ Int64($0) }),
            let crc = values["crc32"].flatMap({ UInt32($0, radix: 16) })
        else { return nil }
        self.init(name: name, size: size, crc: crc)
    }
}

/// Split File (spec 08 › Split file).
enum Splitter {
    /// The sizes of the "Bytes per file" list. 360 k is the usable capacity of the floppy as
    /// the spec records it; the other floppy sizes follow the same rule, the larger media
    /// are taken at their nominal size.
    static let presets: [(title: String, bytes: Int64)] = [
        ("Automatic", 1_457_664), ("1.44 MB (3.5\")", 1_457_664), ("1.2 MB (5.25\")", 1_213_952),
        ("720 k (3.5\")", 730_112),
        ("360 k (5.25\")", 362_496), ("100 MB (ZIP)", 100 << 20), ("250 MB (ZIP)", 250 << 20),
        ("650 MB (CD-R)", 650 << 20),
        ("700 MB (CD-R)", 700 << 20)
    ]
    static let maximumParts = 999

    /// Reads a typed size: bytes, or a number with `k`, `M` or `G` (1 k = 1024 bytes), or the
    /// caption of a preset.
    static func size(from text: String) -> Int64? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if let preset = presets.first(where: { $0.title.caseInsensitiveCompare(text) == .orderedSame }) {
            return preset.bytes
        }
        var digits = text.replacingOccurrences(of: ",", with: "").lowercased()
        if digits.hasSuffix("b"), digits.count > 1, digits.dropLast().last?.isNumber != true { digits.removeLast() }
        var factor = 1.0
        if let unit = digits.last, let shift = ["k": 10.0, "m": 20.0, "g": 30.0][unit] {
            factor = pow(2, shift)
            digits.removeLast()
        }
        guard let number = Double(digits.trimmingCharacters(in: .whitespaces)), number > 0, number * factor < 9e18
        else { return nil }
        let bytes = Int64((number * factor).rounded())
        return bytes > 0 ? bytes : nil
    }

    static func partName(_ base: String, _ number: Int) -> String {
        base + String(format: ".%03d", number)
    }

    /// Writes `<base>.001`, `<base>.002`, … and `<base>.crc` into `directory`.
    ///
    /// Returns the files written. On failure or cancel nothing of them is left, and a file that was
    /// there before is never touched: parts that replace one are written aside and take its place
    /// only when all are done.
    @discardableResult
    static func split(_ source: FileItem, into directory: URL, partSize: Int64, run: ToolRun) throws -> [URL] {
        guard partSize > 0 else { throw ToolError.failed("The size of the parts is not valid.") }
        run.carriesOrigin = true
        // (A size typed by the user, or one a server says: neither may overflow the sum.)
        guard source.size.addingSaturated(partSize - 1) / partSize <= Int64(maximumParts) else {
            throw ToolError.failed("With this size the file would be split into more than \(maximumParts) parts.")
        }
        let base = FileItem.split(source.name).base
        // No output may be the source itself (splitting `data.001` in place): it would be replaced.
        let parts = max(1, Int(source.size.addingSaturated(partSize - 1) / partSize))
        let outputs =
            (1...parts).map { directory.appending(name: partName(base, $0)) } + [
                directory.appending(name: base + ".crc")
            ]
        guard !outputs.contains(where: { ToolRun.isSameFile($0, source.url) }) else {
            throw ToolError.failed("A part of \(source.name) would replace the file itself.")
        }
        // The source is opened before anything is created.
        let reader = try run.openReader(source.url)
        var readerIsOpen = true
        defer { if readerIsOpen { reader.close() } }
        run.expect(bytes: source.size, items: 0)
        return try run.transaction {
            var written: [URL] = []
            let crc = CRC32Hasher()
            var total: Int64 = 0
            func nextPart() throws -> ToolOutput {
                let url = directory.appending(name: partName(base, written.count + 1))
                guard written.count < maximumParts else { throw ToolError.failed("More than \(maximumParts) parts.") }
                run.show([
                    "From: " + run.fileSystems.displayPath(source.url), "To: " + run.fileSystems.displayPath(url)
                ])
                guard let part = try run.create(url, deferred: true) else { throw ToolError.cancelled }
                written.append(part.url)
                return part
            }
            var output = try nextPart()
            readerIsOpen = false
            try run.read(reader) { block in
                crc.update(block)
                total += Int64(block.count)
                var offset = 0
                while offset < block.count {
                    if output.bytesWritten == partSize {
                        try output.finish()
                        output = try nextPart()
                    }
                    let room = Int(min(partSize - output.bytesWritten, Int64(block.count - offset)))
                    try output.write(
                        block.subdata(in: (block.startIndex + offset)..<(block.startIndex + offset + room))
                    )
                    offset += room
                }
            }
            try output.finish()
            let info = SplitInfo(name: source.name, size: total, crc: crc.checksum)
            guard
                let crcFile = try run.write(
                    Data(info.text.utf8),
                    to: directory.appending(name: base + ".crc"),
                    deferred: true
                )
            else {
                throw ToolError.cancelled
            }
            written.append(crcFile)
            return written
        }
    }
}

/// A row of files with an ascending counter in their names (spec 08 › Combine files): a
/// numeric extension (`file.001`), a number inside the name (`name.00000.zip.part`) or the
/// letters of Unix `split` (`fileaa`, `fileab`).
enum PartSeries {
    private enum Counter {
        case digits(Range<String.Index>)
        case letters(Range<String.Index>)
    }

    private static func counter(in name: String) -> Counter? {
        func isDigit(_ character: Character) -> Bool { character.isASCII && character.isNumber }
        // An extension of digits is the counter; otherwise the last run of digits in front of
        // the extension is (the digits of `.b64` or `.mp3` count nothing).
        let dot = name.lastIndex(of: ".")
        let numericExtension =
            dot.map { name.index(after: $0) < name.endIndex && name[name.index(after: $0)...].allSatisfy(isDigit) }
            ?? false
        let searched = numericExtension ? Substring(name) : name[..<(dot ?? name.endIndex)]
        if let last = searched.lastIndex(where: isDigit) {
            var first = last
            while first > name.startIndex, case let before = name.index(before: first), isDigit(name[before]) {
                first = before
            }
            return .digits(first..<name.index(after: last))
        }
        // A name without digits and without an extension counts in its last two letters.
        guard dot == nil, name.count >= 2 else { return nil }
        let start = name.index(name.endIndex, offsetBy: -2)
        return name[start...].allSatisfy { $0.isASCII && $0.isLowercase } ? .letters(start..<name.endIndex) : nil
    }

    /// The name after `name` in its row: the decimal number of the same width, or the
    /// letters a…z with carry (`az` → `ba`).
    ///
    /// Nil when the name has no counter or it is at its end.
    static func next(after name: String) -> String? {
        switch counter(in: name) {
        case .digits(let range):
            let digits = name[range]
            guard digits.count <= 18, let value = Int(digits) else { return nil }
            let next = String(value + 1)
            guard next.count <= digits.count else { return nil }
            return name.replacingCharacters(
                in: range,
                with: String(repeating: "0", count: digits.count - next.count) + next
            )

        case .letters(let range):
            var letters = Array(name[range].utf8)
            var index = letters.count - 1
            while index >= 0 {
                if letters[index] < UInt8(ascii: "z") {
                    letters[index] += 1
                    return name.replacingCharacters(in: range, with: String(decoding: letters, as: UTF8.self))
                }
                letters[index] = UInt8(ascii: "a")
                index -= 1
            }
            return nil

        case nil:
            return nil
        }
    }

    /// The name of the whole when no `.crc` file tells it: the part's name without its counter.
    static func combinedName(forPart name: String) -> String {
        guard let counter = counter(in: name) else { return name }
        var range: Range<String.Index>
        switch counter {
        case .digits(let found), .letters(let found): range = found
        }
        // The dot in front of the counter goes with it: `file.001` → `file`.
        if range.lowerBound > name.startIndex, name[name.index(before: range.lowerBound)] == "." {
            range = name.index(before: range.lowerBound)..<range.upperBound
        }
        let result = name.replacingCharacters(in: range, with: "")
        return result.isEmpty ? name + ".combined" : result
    }

    /// `first` and the files that follow it in its folder, until a name is missing.
    static func parts(
        startingAt first: FileItem,
        provider: any FileSystemProvider,
        cancellation: CancellationFlag = CancellationFlag()
    ) -> [FileItem] {
        var parts = [first]
        let directory = first.url.deletingLastPathComponent()
        var name = first.name
        while let next = next(after: name),
            let item = provider.item(at: directory.appending(name: next), cancellation: cancellation), !item.isDirectory
        {
            parts.append(item)
            name = next
        }
        return parts
    }
}

/// Combine Files (spec 08 › Combine files).
enum Combiner {
    struct Outcome: Equatable {
        var output: URL
        var parts: Int
        /// Whether size and CRC32 match the `.crc` file; nil when there is none.
        var verified: Bool?
    }

    /// What is to be combined when the cursor is on `item`: the row of parts and what the
    /// `.crc` file says.
    ///
    /// The cursor may be on the first part or on the `.crc` file itself.
    static func plan(for item: FileItem, run: ToolRun) throws -> (parts: [FileItem], info: SplitInfo?) {
        let provider = try run.provider(for: item.url)
        let directory = item.url.deletingLastPathComponent()
        var first = item
        if item.ext.lowercased() == "crc" {
            guard
                let part = provider.item(
                    at: directory.appending(name: Splitter.partName(item.baseName, 1)),
                    cancellation: run.cancellation
                )
            else {
                throw ToolError.failed("\(Splitter.partName(item.baseName, 1)) not found!")
            }
            first = part
        }
        let crcFile = directory.appending(name: FileItem.split(first.name).base + ".crc")
        var info: SplitInfo?
        if provider.item(at: crcFile, cancellation: run.cancellation) != nil,
            let data = try? run.contents(of: crcFile, limit: 1 << 16)
        {
            info = SplitInfo(text: String(decoding: data, as: UTF8.self))
        }
        return (PartSeries.parts(startingAt: first, provider: provider, cancellation: run.cancellation), info)
    }

    /// The name a `.crc` file gives to the whole, as a name inside the target folder: what stands
    /// after the last `/` or `\\` (found on the bytes, so that a slash with a combining mark
    /// after it is a slash all the same), never empty, `.` or `..`.
    static func storedName(_ name: String) -> String? {
        guard let name = Decoder.safeName(name, replacingColon: false) else { return nil }
        return name
    }

    static func combine(_ parts: [FileItem], info: SplitInfo?, into directory: URL, run: ToolRun) throws -> Outcome {
        guard let first = parts.first else { throw ToolError.failed("No files selected!") }
        run.carriesOrigin = true
        // A stored name is only a name: it never leads out of the target folder.
        let name = info.flatMap { storedName($0.name) } ?? PartSeries.combinedName(forPart: first.name)
        guard let target = directory.appending(safeName: name) else {
            throw ToolError.failed("The name of the combined file is not a file name.")
        }
        guard !parts.contains(where: { ToolRun.isSameFile($0.url, target) }) else {
            throw ToolError.failed("The combined file would replace one of its parts.")
        }
        run.expect(bytes: parts.reduce(0) { $0.addingSaturated($1.size) }, items: parts.count)
        return try run.transaction {
            guard let output = try run.create(target, deferred: true) else { throw ToolError.cancelled }
            let crc = CRC32Hasher()
            for part in parts {
                run.show([
                    "From: " + run.fileSystems.displayPath(part.url), "To: " + run.fileSystems.displayPath(output.url)
                ])
                try run.read(part.url) { block in
                    crc.update(block)
                    try output.write(block)
                }
                run.advance(0, items: 1)
            }
            try output.finish()
            return Outcome(
                output: output.url,
                parts: parts.count,
                verified: info.map { $0.size == output.bytesWritten && $0.crc == crc.checksum }
            )
        }
    }
}
