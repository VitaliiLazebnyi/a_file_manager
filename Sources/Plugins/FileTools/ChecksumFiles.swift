import AFMKernel
import Foundation

/// The text of checksum files (spec 19 › Checksum files): written by Create checksums, read
/// by Verify.
enum ChecksumFile {
    struct Entry: Equatable {
        var name: String
        /// Lower-case hex.
        var digest: String
        /// The method, where the line or the file's extension tells it; otherwise every
        /// method with a digest of this length is tried.
        var method: ChecksumMethod?
    }

    /// One line without its end: `<digest> *<name>`, or for SFV `<name> <DIGEST>`.
    ///
    /// A name that would be taken for something else is written so that it reads back as itself.
    /// SFV: a name that starts with `;` or `#` (a comment there) or with white space gets `./` in
    /// front. The other formats (GNU): a name with a line break or, then, a backslash is escaped
    /// (`\n`, `\r`, `\\`) and the line starts with a backslash.
    static func line(name: String, digest: [UInt8], method: ChecksumMethod) -> String {
        if method == .crc32 {
            let needsPrefix = name.first.map { $0 == ";" || $0 == "#" || $0.isWhitespace } ?? false
            return "\(needsPrefix ? "./" : "")\(name) \(digest.hex.uppercased())"
        }
        guard hasLineBreak(name) else {
            return "\(digest.hex) *\(name)"
        }
        var escaped = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            switch scalar {
            case "\\":
                escaped.append(contentsOf: "\\\\".unicodeScalars)

            case "\n":
                escaped.append(contentsOf: "\\n".unicodeScalars)

            case "\r":
                escaped.append(contentsOf: "\\r".unicodeScalars)

            default:
                escaped.append(scalar)
            }
        }
        return "\\\(digest.hex) *\(String(escaped))"
    }

    /// Whether a name holds a line feed or carriage return (found on the code points: `\r\n` is one character to Swift).
    static func hasLineBreak(_ name: String) -> Bool {
        name.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
    }

    /// The contents of a checksum file.
    ///
    /// The Unix format ends lines with LF and keeps `/` in paths; the other one is that of the
    /// Windows original: CRLF and `\`. The text is UTF-8; `byteOrderMark` puts the mark in front
    /// that the original needs to read it as such.
    static func contents(
        _ entries: [(name: String, digest: [UInt8])],
        method: ChecksumMethod,
        unixFormat: Bool,
        byteOrderMark: Bool
    ) -> Data {
        let end = unixFormat ? "\n" : "\r\n"
        let text =
            entries.map { entry in
                line(
                    name: unixFormat ? entry.name : entry.name.replacingOccurrences(of: "/", with: "\\"),
                    digest: entry.digest,
                    method: method
                ) + end
            }
            .joined()
        return (byteOrderMark ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(text.utf8)
    }

    /// Whether the mark is written: always when asked for; otherwise only in the Windows
    /// format and when a name needs more than ASCII (there the original would take the text
    /// for the local code page).
    static func needsByteOrderMark(names: [String], unixFormat: Bool, alwaysUTF8: Bool) -> Bool {
        alwaysUTF8 || (!unixFormat && names.contains { !$0.allSatisfy(\.isASCII) })
    }

    private static let byExtension: [String: ChecksumMethod] = {
        var methods = Dictionary(uniqueKeysWithValues: ChecksumMethod.allCases.map { ($0.fileExtension, $0) })
        methods["sha1"] = .sha1
        methods["crc32"] = .crc32
        methods["blake3"] = .blake3
        for method in [ChecksumMethod.sha3_224, .sha3_256, .sha3_384, .sha3_512] {
            methods[method.fileExtension.replacingOccurrences(of: "_", with: "-")] = method
        }
        return methods
    }()

    static func method(forFileNamed name: String) -> ChecksumMethod? {
        byExtension[FileItem.split(name).ext.lowercased()]
    }

    /// The files Verify takes for checksum files: `*.sfv *.md5 *.sha* *.bk3` and the user's
    /// extra masks (the spec's `ChecksumExtraTypes`).
    static func isChecksumFile(_ name: String, extraMasks: String = "") -> Bool {
        checksumFileTest(extraMasks: extraMasks)(name)
    }

    /// The test of `isChecksumFile`, with the mask compiled once for many names.
    static func checksumFileTest(extraMasks: String = "") -> (String) -> Bool {
        let mask = FileMask("*.sfv *.md5 *.sha* *.bk3 " + extraMasks)
        return { mask.matches($0) }
    }

    /// The text of a checksum file: UTF-8 with or without a mark, UTF-16, or the Western code page.
    static func text(from data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            // Damaged UTF-16 is read as far as it goes; what it makes of the rest is not a checksum line and is reported as such.
            return String(data: data, encoding: .utf16) ?? String(decoding: data, as: UTF8.self)
        }
        if data.count >= 2, data.count % 2 == 0 {
            if data[data.startIndex + 1] == 0, let text = String(data: data, encoding: .utf16LittleEndian) {
                return text
            }
            if data[data.startIndex] == 0, let text = String(data: data, encoding: .utf16BigEndian) {
                return text
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
    }

    private static func isHex(_ text: Substring) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    private static let tags: [String: ChecksumMethod] = {
        var tags = Dictionary(uniqueKeysWithValues: ChecksumMethod.allCases.map { ($0.tagName, $0) })
        tags["SHA2-256"] = .sha256
        tags["SHA2-512"] = .sha512
        tags["SHA2-224"] = .sha224
        tags["SHA2-384"] = .sha384
        return tags
    }()

    /// The name of a GNU line that starts with a backslash: `\\` stands for a backslash and `\n` for a line feed.
    private static func unescaped(_ name: String) -> String {
        guard name.contains("\\") else {
            return name
        }
        var result = ""
        var escaped = false
        for character in name {
            if escaped {
                result.append(character == "n" ? "\n" : character == "r" ? "\r" : character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// What was read from a checksum file: its entries, and the numbers of the lines that are
    /// neither an entry nor a comment nor empty.
    struct Parsed {
        var entries: [Entry] = []
        var unreadableLines: [Int] = []
    }

    /// Reads the lines of a checksum file named `fileName`: `<digest> *<name>` (also with two
    /// spaces), the SFV form `<name> <crc>`, the OpenSSL and BSD form `SHA256(name)= <digest>`
    /// and the checksum of a stream `<digest>  -`, which stands for the file the checksum
    /// file is named after.
    ///
    /// Comment lines (`;`, `#`) are passed over, and so is nothing else.
    static func parse(_ text: String, fileName: String) -> [Entry] {
        parseLines(text, fileName: fileName).entries
    }

    /// Like `parse`, and says which lines could not be read.
    ///
    /// A line is a comment only when it cannot be an entry: in an SFV file `;x.txt 1A2B3C4D`
    /// and `#1 hit.txt DC186425` are entries (the name follows the same rule as the others),
    /// and a `;` line that does not end in a CRC is a comment. The other formats start every entry
    /// with a digest or a tag, so a line starting with `;` or `#` is always a comment there.
    static func parseLines(_ text: String, fileName: String) -> Parsed {
        let fileMethod = method(forFileNamed: fileName)
        func fittingFileMethod(_ digest: Substring) -> ChecksumMethod? {
            fileMethod.flatMap { $0.digestLength * 2 == digest.count ? $0 : nil }
        }
        /// `name crc` at the end of a line, the SFV form.
        func sfvEntry(_ line: String) -> Entry? {
            guard let space = line.lastIndex(where: { $0 == " " || $0 == "\t" }) else {
                return nil
            }
            let digest = line[line.index(after: space)...]
            let name = line[..<space].trimmingCharacters(in: .whitespaces)
            guard isHex(digest), digest.count == 8, !name.isEmpty else {
                return nil
            }
            return Entry(name: name, digest: digest.lowercased(), method: .crc32)
        }
        var parsed = Parsed()
        // Lines end with LF, CR or CRLF only: other line separators of Unicode can be part of a name.
        let lines = text.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
        )
        for (index, rawLine) in lines.enumerated() {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix(";") || line.hasPrefix("#") {
                if fileMethod == .crc32, let entry = sfvEntry(line) { parsed.entries.append(entry) }
                continue
            }
            // GNU tools put a backslash in front of a line whose name holds a backslash or a line feed.
            let escaped =
                line.hasPrefix("\\")
                && line.dropFirst().prefix { $0 != " " && $0 != "\t" }.allSatisfy { $0.isASCII && $0.isHexDigit }
            if escaped { line.removeFirst() }
            func decoded(_ text: String) -> String { escaped ? unescaped(text) : text }
            // SHA256(name)= digest   /   MD5 (name) = digest
            if let open = line.firstIndex(of: "("), let close = line.range(of: ")", options: .backwards)?.lowerBound,
                open < close,
                let tagged = tags[
                    line[..<open].trimmingCharacters(in: .whitespaces).uppercased()
                        .replacingOccurrences(
                            of: "_",
                            with: "-"
                        )
                ]
            {
                let digest = line[line.index(after: close)...].drop { $0 == "=" || $0 == " " }
                let name = decoded(String(line[line.index(after: open)..<close]))
                if isHex(digest), digest.count == tagged.digestLength * 2, !name.isEmpty {
                    parsed.entries.append(Entry(name: name, digest: digest.lowercased(), method: tagged))
                    continue
                }
            }
            let first = line.prefix { $0 != " " && $0 != "\t" }
            let rest = line[first.endIndex...]
            let known = !ChecksumMethod.candidates(hexDigits: first.count).isEmpty
            // In an SFV file a line is `name crc` even when the name starts like a checksum.
            if isHex(first), known, rest.count >= 2,
                fileMethod != .crc32 || first.count != 8 || !isHex(line.suffix(8)) || line.count < 10
            {
                var name = rest.dropFirst()
                if name.hasPrefix("*") || name.hasPrefix(" ") { name = name.dropFirst() }
                let isStream = name == "-"
                let entryName = isStream ? FileItem.split(fileName).base : decoded(String(name))
                // `<digest> *` names nothing.
                if entryName.isEmpty {
                    parsed.unreadableLines.append(index + 1)
                } else {
                    parsed.entries.append(
                        Entry(name: entryName, digest: first.lowercased(), method: fittingFileMethod(first))
                    )
                }
                continue
            }
            if let entry = sfvEntry(line) {
                parsed.entries.append(entry)
            } else {
                parsed.unreadableLines.append(index + 1)
            }
        }
        return parsed
    }
}

/// What Verify found for one file.
enum VerifyResult: Equatable {
    case ok, notFound, readError, wrongChecksum
    /// Something in the checksum file itself that cannot be read: a line, or the whole file.
    case unreadable
}

/// The outcome of Verify checksums, and its text (spec 08 › Verify window).
struct VerifyReport {
    struct Section {
        var title: String
        var rows: [(name: String, result: VerifyResult)]
    }

    var sections: [Section] = []
    var methods: Set<ChecksumMethod> = []

    func count(_ result: VerifyResult) -> Int {
        sections.reduce(0) { $0 + $1.rows.filter { $0.result == result }.count }
    }

    var errors: Int { count(.notFound) + count(.readError) + count(.wrongChecksum) + count(.unreadable) }

    /// The names of the files that failed, as the panel knows them; where the checksum file itself is
    /// at fault, its own name (the title of the section).
    var failedNames: [String] {
        sections.flatMap { section in
            section.rows.filter { $0.result != .ok }.map { $0.result == .unreadable ? section.title : $0.name }
        }
    }

    /// `<METHOD>: Errors: N`.
    var title: String {
        let method = methods.count == 1 ? methods.map(\.reportName).joined() : "Checksums"
        return "\(method): Errors: \(errors)"
    }

    static func row(_ name: String, _ result: VerifyResult) -> String {
        switch result {
        case .ok:
            return "OK:  \(name)"

        case .notFound:
            return "Cannot open input file \(name)!"

        case .readError:
            return "Error reading file \(name)!"

        case .wrongChecksum:
            return "Wrong checksum: \(name)!"

        case .unreadable:
            return "Cannot read \(name)!"
        }
    }

    /// The rows of the window; with `onlyErrors` just the failures and the summary.
    func text(onlyErrors: Bool) -> String {
        var lines: [String] = []
        for section in sections {
            lines.append(section.title + ":")
            lines += section.rows.filter { !onlyErrors || $0.result != .ok }
                .map {
                    Self.row($0.name, $0.result)
                }
            lines.append("")
        }
        lines.append("Errors: \(errors)")
        lines.append(
            "OK: \(count(.ok)), not found: \(count(.notFound)), read error: \(count(.readError)), wrong checksum: \(count(.wrongChecksum))"
                + (count(.unreadable) > 0 ? ", unreadable: \(count(.unreadable))" : "")
        )
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Hashing many files, and the two checksum tools built on it.
///
/// **Threading.** Everything here blocks and runs on a job's thread. The files are hashed on
/// all cores at once, each file as a stream of blocks on one of them; the results come back
/// in the order of the input.
enum ChecksumRun {
    /// The digests of each file for each of its methods, or the error that stopped it.
    ///
    /// With an `expected` digest and several methods of that length only the first (the likeliest)
    /// is computed in a first pass over the file; the others, all in one further pass, only when it
    /// does not match. The digests of methods not computed are empty.
    static func digests(of files: [(url: URL, methods: [ChecksumMethod], expected: String?)], run: ToolRun) -> [Result<
        [[UInt8]], any Error
    >] {
        let busy = BusyFiles()
        return Parallel.map(files) { file -> Result<[[UInt8]], any Error> in
            busy.enter()
            defer { busy.leave() }
            return Result {
                func hash(_ methods: [ChecksumMethod], counted: Bool) throws -> [[UInt8]] {
                    let hashers = methods.map { $0.makeHasher() }
                    // Several methods in one pass over the file: each block goes to every
                    // hasher at the same time, each on its own thread.
                    // BLAKE3 spreads a block over the cores itself, which pays only for large ones.
                    try run.read(
                        file.url,
                        counted: counted,
                        blockSize: methods.contains(.blake3) ? 4 << 20 : ToolRun.blockSize
                    ) { block in
                        // BLAKE3 spreads a large block over the cores on its own; while the files themselves
                        // keep every core busy that only makes more threads than cores, so it is fed pieces too
                        // small to be spread then (the digest is the same).
                        let spread = spreadsBLAKE3(filesInProgress: busy.count)
                        if hashers.count > 1 {
                            _ = Parallel.map(hashers) { feed($0, block, spread: spread) }
                        } else {
                            hashers.forEach { feed($0, block, spread: spread) }
                        }
                    }
                    return hashers.map { $0.finish() }
                }
                let found: [[UInt8]]
                if let expected = file.expected, file.methods.count > 1 {
                    let first = try hash([file.methods[0]], counted: true)
                    if first[0].hex == expected {
                        found = first + Array(repeating: [], count: file.methods.count - 1)
                    } else {
                        // The second pass is not counted: the bar has been to the end of this file already.
                        found = first + (try hash(Array(file.methods.dropFirst()), counted: false))
                    }
                } else {
                    found = try hash(file.methods, counted: true)
                }
                run.advance(0, items: 1)
                return found
            }
        }
    }

    /// How many files are being hashed at this moment.
    ///
    /// Unchecked `Sendable`: `active` is guarded by `lock`.
    private final class BusyFiles: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return active
        }

        func enter() {
            lock.lock()
            active += 1
            lock.unlock()
        }

        func leave() {
            lock.lock()
            active -= 1
            lock.unlock()
        }
    }

    /// Whether BLAKE3 may spread a block over the cores now: when fewer files than cores are
    /// being hashed, so that cores are left over.
    static func spreadsBLAKE3(filesInProgress: Int, cores: Int = ProcessInfo.processInfo.activeProcessorCount) -> Bool {
        filesInProgress < cores
    }

    /// The pieces BLAKE3 is fed when it must not spread the work: smaller than the 16 chunks (16 KB)
    /// from which it uses more than one thread.
    static let serialPiece = 8 << 10

    /// Gives `block` to `hasher`; to a BLAKE3 hasher that must not spread it, piece by piece.
    static func feed(_ hasher: any StreamHasher, _ block: Data, spread: Bool) {
        guard hasher is BLAKE3Hasher, !spread, block.count > serialPiece else {
            hasher.update(block)
            return
        }
        var start = block.startIndex
        while start < block.endIndex {
            let end = min(block.endIndex, start + serialPiece)
            hasher.update(block[start..<end])
            start = end
        }
    }

    static func digests(of files: [(url: URL, methods: [ChecksumMethod])], run: ToolRun) -> [Result<
        [[UInt8]], any Error
    >] {
        digests(of: files.map { ($0.url, $0.methods, nil) }, run: run)
    }

    /// The files below the operands, in listing order; folders are walked recursively and
    /// links to folders are not followed.
    static func files(below operands: [FileItem], run: ToolRun) throws -> [FileItem] {
        var files: [FileItem] = []
        for operand in operands {
            try run.checkCancelled()
            if operand.isRealDirectory {
                let items = try run.provider(for: operand.url)
                    .list(
                        operand.url,
                        showHidden: true,
                        cancellation: run.cancellation
                    )
                files += try self.files(below: Sorter.sorted(items, numeric: true, byName: \.name), run: run)
            } else if !operand.isDirectory {
                files.append(operand)
            }
        }
        return files
    }

    struct CreateOptions: Equatable {
        var method = ChecksumMethod.crc32
        var separatePerFile = false
        var separatePerFolder = false
        var alwaysUTF8 = false
        var unixFormat = true
    }

    /// The checksum file a file is listed in.
    static func outputURL(for file: FileItem, target: URL, options: CreateOptions) -> URL {
        if options.separatePerFolder {
            // One file per folder, written into that folder; the target path is not used.
            let folder = file.url.deletingLastPathComponent()
            let folderName =
                folder.lastPathComponent.isEmpty || folder.lastPathComponent == "/"
                ? "checksums" : folder.lastPathComponent
            return folder.appending(name: folderName + "." + options.method.fileExtension)
        }
        if options.separatePerFile {
            return target.deletingLastPathComponent()
                .appending(
                    name: separateName(for: file.name, pattern: target.lastPathComponent, method: options.method)
                )
        }
        return target
    }

    /// How a file is named inside a checksum file in `folder`: by its path from there when it
    /// lies below, else by its full path (a bare name would be ambiguous and lead nowhere).
    static func name(of file: URL, in folder: URL) -> String {
        guard file.isInside(folder) else {
            return file.path
        }
        return String(file.path.dropFirst(folder.path.count).drop { $0 == "/" })
    }

    /// The name of the checksum file of one file, from a pattern with `*`: `*.*.sfv` adds
    /// the extension to the whole name, `*.sfv` puts it in place of the file's own.
    static func separateName(for fileName: String, pattern: String, method: ChecksumMethod) -> String {
        let stars = pattern.filter { $0 == "*" }.count
        let patternExtension = FileItem.split(pattern).ext
        let ext = patternExtension.isEmpty || patternExtension.contains("*") ? method.fileExtension : patternExtension
        return (stars >= 2 ? fileName : FileItem.split(fileName).base) + "." + ext
    }

    /// Hashes the files and writes the checksum file(s).
    ///
    /// `target` is the checksum file for all, or, with separate files, the folder and pattern for
    /// them. Returns what was written.
    static func create(for operands: [FileItem], target: URL, options: CreateOptions, run: ToolRun) throws -> [URL] {
        var files = try files(below: operands, run: run)
        // A checksum file among the operands is about to be replaced: it is not hashed, or the
        // new one would list itself with a stale digest.
        let outputs = Set(files.map { outputURL(for: $0, target: target, options: options).locationKey })
        files.removeAll { outputs.contains($0.url.locationKey) }
        guard !files.isEmpty else { throw ToolError.failed("No files selected!") }
        run.expect(bytes: files.reduce(0) { $0.addingSaturated($1.size) }, items: files.count)
        run.show(["Creating \(options.method.title) checksums"])
        let digests = digests(of: files.map { ($0.url, [options.method]) }, run: run)
        try run.checkCancelled()
        // One unreadable file fails the whole: a checksum file that silently lacks files would mislead.
        var entries: [(file: FileItem, digest: [UInt8])] = []
        for (file, result) in zip(files, digests) {
            switch result {
            case .success(let found):
                entries.append((file, found[0]))

            case .failure(let error):
                throw ToolError.failed("\(file.name): \(error.localizedDescription)")
            }
        }
        /// The checksum files to write, in order, each with its entries.
        var groups: [(url: URL, entries: [(name: String, digest: [UInt8])])] = []
        var groupIndex: [String: Int] = [:]
        for entry in entries {
            let url = outputURL(for: entry.file, target: target, options: options)
            // Names are relative to the checksum file's folder; files elsewhere keep their full path.
            var name = Self.name(of: entry.file.url, in: url.deletingLastPathComponent())
            if options.separatePerFolder || (options.separatePerFile && name.hasPrefix("/")) { name = entry.file.name }
            if let index = groupIndex[url.locationKey] {
                groups[index].entries.append((name, entry.digest))
            } else {
                groupIndex[url.locationKey] = groups.count
                groups.append((url, [(name, entry.digest)]))
            }
        }
        // Several files that would share one checksum file under one name cannot be told apart in it.
        if options.separatePerFile, groups.contains(where: { Set($0.entries.map(\.name)).count != $0.entries.count }) {
            throw ToolError.failed("Several files with the same name would get the same checksum file.")
        }
        // A line break in a name cannot be written to an SFV file (it has no escape), and would break the file.
        if options.method == .crc32,
            let bad = groups.lazy.flatMap({ $0.entries }).first(where: { ChecksumFile.hasLineBreak($0.name) })
        {
            throw ToolError.failed(
                "\(bad.name.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")): a name with a line break cannot be written to an SFV file."
            )
        }
        // All checksum files are replaced together at the end, or none: a cancel leaves the old ones as they were.
        return try run.transaction {
            var written: [URL] = []
            for group in groups {
                let mark = ChecksumFile.needsByteOrderMark(
                    names: group.entries.map(\.name),
                    unixFormat: options.unixFormat,
                    alwaysUTF8: options.alwaysUTF8
                )
                try run.provider(for: group.url).createDirectory(at: group.url.deletingLastPathComponent())
                let data = ChecksumFile.contents(
                    group.entries,
                    method: options.method,
                    unixFormat: options.unixFormat,
                    byteOrderMark: mark
                )
                if let url = try run.write(data, to: group.url, deferred: true) { written.append(url) }
            }
            return written
        }
    }

    /// Checks the files listed in checksum files against their checksums.
    static func verify(checksumFiles: [FileItem], run: ToolRun) throws -> VerifyReport {
        var report = VerifyReport()
        struct Pending {
            var section: Int
            var name: String
            var url: URL
            var entry: ChecksumFile.Entry
            var methods: [ChecksumMethod]
            var size: Int64?
        }
        var pending: [Pending] = []
        for file in checksumFiles {
            try run.checkCancelled()
            let provider = try run.provider(for: file.url)
            let folder = file.url.deletingLastPathComponent()
            report.sections.append(VerifyReport.Section(title: file.name, rows: []))
            let parsed: ChecksumFile.Parsed
            do {
                parsed = ChecksumFile.parseLines(
                    ChecksumFile.text(from: try run.contents(of: file.url)),
                    fileName: file.name
                )
            } catch {
                // A checksum file that cannot be read is an error of its own; the others are still checked.
                try run.checkCancelled()
                report.sections[report.sections.count - 1].rows
                    .append(
                        ("the file (\(error.localizedDescription))", .unreadable)
                    )
                continue
            }
            // What cannot be read is never "no errors": every such line counts, and so does a file without checksums.
            for number in parsed.unreadableLines {
                report.sections[report.sections.count - 1].rows.append(("line \(number)", .unreadable))
            }
            if parsed.entries.isEmpty, parsed.unreadableLines.isEmpty {
                report.sections[report.sections.count - 1].rows
                    .append(
                        ("any checksum (the file has none)", .unreadable)
                    )
            }
            for entry in parsed.entries {
                // A name is taken as written; a Windows path is tried with `/` when that finds nothing.
                // An absolute path stands for itself, not below the checksum file's folder.
                func resolve(_ name: String) -> URL {
                    if name.hasPrefix("/"), folder.isFileURL {
                        return URL(fileURLWithPath: name).standardized
                    }
                    return folder.appendingPathComponent(name, isDirectory: false).standardized
                }
                var url = resolve(entry.name)
                var item = provider.item(at: url, cancellation: run.cancellation)
                if item == nil, entry.name.contains("\\") {
                    url = resolve(entry.name.replacingOccurrences(of: "\\", with: "/"))
                    item = provider.item(at: url, cancellation: run.cancellation)
                }
                let methods = entry.method.map { [$0] } ?? ChecksumMethod.candidates(hexDigits: entry.digest.count)
                // The title names the method; of several that share a length, the first (SHA-2).
                if let named = methods.first { report.methods.insert(named) }
                pending.append(
                    Pending(
                        section: report.sections.count - 1,
                        name: entry.name,
                        url: url,
                        entry: entry,
                        methods: methods,
                        size: item.flatMap { $0.isDirectory ? nil : $0.size }
                    )
                )
            }
        }
        let present = pending.filter { $0.size != nil }
        let sizes = pending.compactMap(\.size)
        run.expect(bytes: sizes.reduce(0) { $0.addingSaturated($1) }, items: sizes.count)
        run.show(["Verifying checksums"])
        let digests = digests(of: present.map { ($0.url, $0.methods, $0.entry.digest) }, run: run)
        try run.checkCancelled()
        var hashed = digests.makeIterator()
        for file in pending {
            var result = VerifyResult.notFound
            if file.size != nil, let outcome = hashed.next() {
                switch outcome {
                case .success(let found):
                    result = found.contains { $0.hex == file.entry.digest } ? .ok : .wrongChecksum

                case .failure:
                    result = .readError
                }
            }
            report.sections[file.section].rows.append((file.name, result))
        }
        return report
    }

    /// Checks files against one checksum each, given from outside: the clipboard, or a CRC32
    /// in square brackets in the name.
    ///
    /// Every method the length of the checksum allows is tried.
    static func verify(_ files: [(item: FileItem, digest: String)], title: String, run: ToolRun) throws -> VerifyReport
    {
        var report = VerifyReport()
        let methods = files.map { ChecksumMethod.candidates(hexDigits: $0.digest.count) }
        if let first = methods.first?.first { report.methods = [first] }
        run.expect(bytes: files.reduce(0) { $0.addingSaturated($1.item.size) }, items: files.count)
        run.show(["Verifying checksums"])
        let digests = digests(
            of: zip(files, methods).map { ($0.0.item.url, $0.1, $0.0.digest.lowercased()) },
            run: run
        )
        try run.checkCancelled()
        var rows: [(name: String, result: VerifyResult)] = []
        for (index, file) in files.enumerated() {
            switch digests[index] {
            case .success(let found):
                if let match = found.firstIndex(where: { $0.hex == file.digest.lowercased() }) {
                    report.methods = [methods[index][match]]
                }
                rows.append(
                    (file.item.name, found.contains { $0.hex == file.digest.lowercased() } ? .ok : .wrongChecksum)
                )

            case .failure:
                rows.append((file.item.name, .readError))
            }
        }
        report.sections = [VerifyReport.Section(title: title, rows: rows)]
        return report
    }

    private static let bracketedChecksum = try? NSRegularExpression(pattern: #"\[([0-9A-Fa-f]{8})\]"#)

    /// A CRC32 in square brackets in a file name: `Movie [1A2B3C4D].mkv`.
    static func checksumInName(_ name: String) -> String? {
        guard name.utf8.contains(UInt8(ascii: "[")), let regex = bracketedChecksum,
            let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
            let range = Range(match.range(at: 1), in: name)
        else { return nil }
        return name[range].lowercased()
    }

    /// A checksum on the clipboard: nothing but hex digits of a known length.
    static func checksum(fromClipboard text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
            text.allSatisfy({ $0.isASCII && $0.isHexDigit }),
            !ChecksumMethod.candidates(hexDigits: text.count).isEmpty
        else { return nil }
        return text.lowercased()
    }
}
