import AFMKernel
import Foundation

/// The file comments of one folder, as Total Commander keeps them in `descript.ion`
/// (spec 19 › `descript.ion` and `files.bbs`, 07 › File comments): one line per file, the name
/// (in double quotes when it holds a space), a space, the comment, CRLF.
///
/// A value type without any file access; `CommentStore` reads and writes it.
struct DescriptIon: Equatable {
    static let fileName = "descript.ion"
    /// The longest comment the format takes.
    static let commentLimit = 4_095
    /// Follows a comment of several lines, whose lines are joined with a literal `\n`.
    private static let multilineMarker = "\u{04}\u{C2}"

    /// How the file is written.
    ///
    /// A new file is plain text, and becomes UTF-16 only when a name or a comment needs it
    /// (`CommentPreferredFormat=4`, the default).
    enum Encoding: Equatable {
        case ansi
        case utf8(bom: Bool)
        case utf16LittleEndian, utf16BigEndian
    }

    struct Entry: Equatable {
        var name: String
        /// With real line breaks (`\n`) between the lines.
        var comment: String
    }

    /// In the order of the file, which is kept when the file is written again.
    private(set) var entries: [Entry] = []
    private(set) var encoding = Encoding.ansi

    init() {}

    /// Reads whatever can be read; a file that cannot be decoded gives no comments.
    init(data: Data) {
        self.init(decoded: Self.decode(data) ?? ("", .ansi))
    }

    /// Nil when the bytes cannot be decoded in the encoding their start announces.
    init?(strict data: Data) {
        guard let decoded = Self.decode(data) else {
            return nil
        }
        self.init(decoded: decoded)
    }

    private init(decoded: (String, Encoding)) {
        let (text, encoding) = decoded
        self.encoding = encoding
        // Lines are cut where the file has a line feed, whatever stands next to it: taken by
        // characters, a line feed that follows a carriage return would be half of one.
        for line in text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: true) {
            if let entry = Self.parse(line.last == "\r" ? line.dropLast() : line) { entries.append(entry) }
        }
    }

    private static func decode(_ data: Data) -> (String, Encoding)? {
        func text(_ data: Data, _ encoding: String.Encoding) -> String? { String(data: data, encoding: encoding) }
        if data.starts(with: [0xFF, 0xFE]) {
            return text(data.dropFirst(2), .utf16LittleEndian).map { ($0, .utf16LittleEndian) }
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return text(data.dropFirst(2), .utf16BigEndian).map { ($0, .utf16BigEndian) }
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return text(data.dropFirst(3), .utf8).map { ($0, .utf8(bom: true)) }
        }
        // Plain ASCII reads the same either way. Text that is valid UTF-8 is taken as such;
        // anything else is the Windows code page Total Commander writes by default.
        if let utf8 = String(data: data, encoding: .utf8) {
            return (utf8, data.allSatisfy { $0 < 0x80 } ? .ansi : .utf8(bom: false))
        }
        // What the code page leaves undefined is read as Latin-1, byte for character.
        let ansi = text(data, .windowsCP1252) ?? String(String.UnicodeScalarView(data.map { Unicode.Scalar($0) }))
        return (ansi, .ansi)
    }

    /// Reads one line.
    ///
    /// The separators (the quotes around a name, the space after it) are looked for scalar by
    /// scalar, as the file has them: taken by characters, a space or a quote followed by a
    /// combining mark is one character with it and would not be found.
    private static func parse(_ line: Substring.UnicodeScalarView) -> Entry? {
        var name: Substring.UnicodeScalarView
        var rest: Substring.UnicodeScalarView
        if line.first == "\"" {
            let body = line.dropFirst()
            guard let quote = body.firstIndex(of: "\"") else {
                return nil
            }
            (name, rest) = (body[..<quote], body[body.index(after: quote)...])
        } else {
            let space = line.firstIndex(of: " ") ?? line.endIndex
            (name, rest) = (line[..<space], line[space...])
        }
        if rest.first == " " { rest = rest.dropFirst() }
        guard !name.isEmpty else {
            return nil
        }
        var comment = String(Substring(rest))
        let marker = Array(multilineMarker.unicodeScalars)
        if rest.count >= marker.count, Array(rest.suffix(marker.count)) == marker {
            comment = String(Substring(rest.dropLast(marker.count)))
                .replacingOccurrences(
                    of: "\\n",
                    with: "\n",
                    options: .literal
                )
        }
        return Entry(name: String(Substring(name)), comment: comment)
    }

    /// Whether the file can hold a comment for this name and give it back: a name is written
    /// as it is, or between quotes when it holds a space, and nothing in the format escapes a
    /// quote or a line break.
    static func canName(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        if scalars.isEmpty || scalars.contains(where: { $0 == "\n" || $0 == "\r" }) {
            return false
        }
        let hasQuote = scalars.contains("\"")
        return !(scalars.first == "\"" || (hasQuote && scalars.contains(" ")))
    }

    /// Names are compared without regard to case, as the shipped `DESCRIPT.ION` writes them in
    /// capitals.
    func comment(for name: String) -> String? {
        let wanted = name.lowercased()
        return entries.first { $0.name.lowercased() == wanted }?.comment
    }

    /// The comments by lower-cased name, for looking up many files of a folder.
    var commentsByName: [String: String] {
        Dictionary(entries.map { ($0.name.lowercased(), $0.comment) }, uniquingKeysWith: { first, _ in first })
    }

    /// Sets, replaces or (with an empty text) removes the comment of a file.
    mutating func setComment(_ comment: String, for name: String) {
        let comment = Self.normalized(comment)
        let wanted = name.lowercased()
        let index = entries.firstIndex { $0.name.lowercased() == wanted }
        switch (index, comment.isEmpty) {
        case (let index?, true):
            entries.remove(at: index)

        case (let index?, false):
            entries[index].comment = comment

        case (nil, false):
            entries.append(Entry(name: name, comment: comment))

        case (nil, true):
            break
        }
    }

    /// Line ends as `\n`, and no empty lines or spaces at the end.
    static func normalized(_ comment: String) -> String {
        var text = comment.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        while let last = text.last, last == "\n" || last == " " { text.removeLast() }
        return text
    }

    var isEmpty: Bool { entries.isEmpty }

    /// The file's bytes.
    ///
    /// The encoding the file was read in is kept as long as it can hold every character; plain text
    /// that cannot becomes UTF-16 LE with a byte-order mark.
    func data() -> Data {
        var text = ""
        for entry in entries {
            text += entry.name.unicodeScalars.contains(" ") ? "\"\(entry.name)\"" : entry.name
            text += " "
            if entry.comment.unicodeScalars.contains("\n") {
                text +=
                    entry.comment.replacingOccurrences(of: "\n", with: "\\n", options: .literal)
                    + Self.multilineMarker
            } else {
                text += entry.comment
            }
            text += "\r\n"
        }
        /// A file without a byte-order mark must not begin with the bytes of one (a first name
        /// such as `ÿþ…` would): it would be read in another encoding, or not at all. An empty
        /// line in front, which every reader skips, keeps them from the start.
        func unmarked(_ data: Data) -> Data {
            let marks: [[UInt8]] = [[0xFF, 0xFE], [0xFE, 0xFF], [0xEF, 0xBB, 0xBF]]
            return marks.contains { data.starts(with: $0) } ? Data([0x0D, 0x0A]) + data : data
        }
        switch encoding {
        case .ansi:
            if let plain = text.data(using: .windowsCP1252) {
                let bytes = unmarked(plain)
                // A file without a mark is read as UTF-8 when its bytes happen to be valid
                // UTF-8, and only otherwise in the Windows code page. Names whose code-page
                // bytes are valid UTF-8 (`Ã©`, or the three bytes of a byte-order mark,
                // `ï»¿`) would come back as other names. Such a file is written as UTF-8
                // with its mark, which says what it is: every name reads back as it was.
                if bytes.contains(where: { $0 >= 0x80 }), String(data: bytes, encoding: .utf8) != nil {
                    return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
                }
                return bytes
            }
            return Data([0xFF, 0xFE]) + Self.utf16(text, bigEndian: false)

        case .utf8(let bom):
            return bom ? Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8) : unmarked(Data(text.utf8))

        case .utf16LittleEndian:
            return Data([0xFF, 0xFE]) + Self.utf16(text, bigEndian: false)

        case .utf16BigEndian:
            return Data([0xFE, 0xFF]) + Self.utf16(text, bigEndian: true)
        }
    }

    /// The text in UTF-16, without a byte-order mark.
    private static func utf16(_ text: String, bigEndian: Bool) -> Data {
        Data(
            text.utf16.flatMap { unit in
                let (high, low) = (UInt8(unit >> 8), UInt8(unit & 0xFF))
                return bigEndian ? [high, low] : [low, high]
            }
        )
    }
}

/// Reads and writes the comment files through the file-system providers, so comments work
/// wherever files can be written, and remembers what it read.
///
/// **Threading.** Every method may be called from any thread, several at once; none belongs on
/// the main thread, because all of them may read a file. The Comment column asks for every row
/// of a folder on several threads: the folder's file is then read once, and the other threads
/// wait for that reading instead of starting their own. Nobody waits for ever: a reading
/// ends when its caller's flag is set, and a thread that waits for another's reading gives
/// up when its own flag is set or after `waitLimit` (the reader may be held by a server
/// that has stopped answering, with a flag nobody sets).
///
/// `remembered`, `beingRead`, `generations` and `waitLimit` are guarded by `condition`.
final class CommentStore: @unchecked Sendable {
    private struct Remembered {
        let comments: [String: String]
        let read: Date
    }

    /// Comment files larger than this are not read; no folder has that many comments.
    private static let sizeLimit = 16 * 1_024 * 1_024
    /// How long a reading is trusted.
    ///
    /// Changes made here are known at once (`forget`); this is for changes other programs make.
    private static let lifetime: TimeInterval = 3
    /// How long a thread waits for another thread's reading of the same folder.
    var waitLimit: TimeInterval {
        get { condition.withLock { patience } }
        set { condition.withLock { patience = newValue } }
    }
    private var patience: TimeInterval = 10
    /// How often a waiting thread looks at its flag.
    private static let waitStep: TimeInterval = 0.1

    private let fileSystems: FileSystemRegistry
    private let condition = NSCondition()
    private var remembered: [String: Remembered] = [:]
    private var beingRead: Set<String> = []
    /// Counts the changes made to each folder's comments here.
    ///
    /// A reading that began before a change is not remembered: it may be the file as it was.
    private var generations: [String: Int] = [:]

    init(fileSystems: FileSystemRegistry) {
        self.fileSystems = fileSystems
    }

    /// The comment of an item, on one line; empty when it has none.
    func comment(for item: FileItem, cancellation: CancellationFlag = CancellationFlag()) -> String {
        comments(in: item.url.deletingLastPathComponent(), cancellation: cancellation)[item.name.lowercased()] ?? ""
    }

    /// The comments of a folder by lower-cased file name.
    ///
    /// Nothing when `cancellation` was set before they were read, or when another thread's reading
    /// did not come back in time.
    func comments(in directory: URL, cancellation: CancellationFlag = CancellationFlag()) -> [String: String] {
        let key = directory.locationKey
        condition.lock()
        let patience = Date().addingTimeInterval(self.patience)
        while true {
            if let known = remembered[key], -known.read.timeIntervalSinceNow < Self.lifetime {
                condition.unlock()
                return known.comments
            }
            if !beingRead.contains(key) { break }
            // The reader may never come back; whoever waits for it looks up now and then.
            if cancellation.isCancelled || Date() >= patience {
                condition.unlock()
                return [:]
            }
            condition.wait(until: min(patience, Date().addingTimeInterval(Self.waitStep)))
        }
        beingRead.insert(key)
        let generation = generations[key] ?? 0
        condition.unlock()

        let comments = load(directory, cancellation: cancellation).commentsByName
        condition.lock()
        if remembered.count > 256 { remembered.removeAll() }
        // Changed here while it was being read: what was read is returned, but not kept.
        // Nor is a reading that was cut short: it is not what the file holds.
        if (generations[key] ?? 0) == generation, !cancellation.isCancelled {
            remembered[key] = Remembered(comments: comments, read: Date())
        }
        beingRead.remove(key)
        condition.broadcast()
        condition.unlock()
        return comments
    }

    func forget(_ directory: URL) {
        let key = directory.locationKey
        condition.lock()
        remembered[key] = nil
        if generations.count > 4_096 { generations = generations.filter { beingRead.contains($0.key) } }
        generations[key, default: 0] += 1
        condition.unlock()
    }

    /// The comment file of a folder; empty when there is none, it cannot be read, or
    /// `cancellation` was set before all of it was read (a read that waits for a server is
    /// ended by the flag).
    func load(_ directory: URL, cancellation: CancellationFlag = CancellationFlag()) -> DescriptIon {
        let url = directory.appending(name: DescriptIon.fileName)
        // Something that is called `descript.ion` and is a pipe would never finish being read.
        guard !cancellation.isCancelled, LocalInfo.canBeRead(url),
            let reader = try? fileSystems.provider(for: url).read(url, cancellation: cancellation)
        else { return DescriptIon() }
        defer { reader.close() }
        let token = cancellation.interrupting(reader)
        defer { withExtendedLifetime(token) {} }
        var data = Data()
        while let block = autoreleasepool(invoking: { try? reader.read(upToCount: 1 << 20) }) {
            if cancellation.isCancelled {
                return DescriptIon()
            }
            data.append(block)
            if data.count > Self.sizeLimit {
                return DescriptIon()
            }
        }
        return cancellation.isCancelled ? DescriptIon() : DescriptIon(data: data)
    }

    /// The comment file of a folder for a change that rewrites it: absent is an empty one, but a
    /// file that is there and cannot be read whole (no permission, too large, not decodable)
    /// throws, because writing it afterwards would destroy every other comment in it.
    func loadForUpdate(_ directory: URL, cancellation: CancellationFlag = CancellationFlag()) throws -> DescriptIon {
        let url = directory.appending(name: DescriptIon.fileName)
        let provider = try fileSystems.provider(for: url)
        guard LocalInfo.canBeRead(url) else { throw CommentFileError.unreadable }
        let reader: any FileReader
        do {
            reader = try provider.read(url, cancellation: cancellation)
        } catch {
            // "Not there" must be known, not guessed from a question that was cut short.
            if provider.item(at: url, cancellation: cancellation) == nil, !cancellation.isCancelled {
                return DescriptIon()
            }
            throw cancellation.isCancelled ? CocoaError(.userCancelled) : CommentFileError.unreadable
        }
        defer { reader.close() }
        let token = cancellation.interrupting(reader)
        defer { withExtendedLifetime(token) {} }
        var data = Data()
        do {
            while let block = try reader.read(upToCount: 1 << 20) {
                data.append(block)
                if data.count > Self.sizeLimit { throw CommentFileError.unreadable }
            }
        } catch {
            throw cancellation.isCancelled ? CocoaError(.userCancelled) : CommentFileError.unreadable
        }
        // A reading that the flag ended is not the file: nothing is written from it.
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        guard let file = DescriptIon(strict: data) else { throw CommentFileError.unreadable }
        return file
    }

    /// Changes the comment of one file.
    ///
    /// The new comment file is written beside the old one and then takes its place in one step, so
    /// a failure leaves the old comments as they were. A file without comments is removed. With
    /// `hidden`, the file gets the hidden flag where the file system has one (a new `descript.ion`
    /// is hidden in Total Commander).
    func setComment(
        _ comment: String,
        for name: String,
        in directory: URL,
        hidden: Bool,
        cancellation: CancellationFlag = CancellationFlag()
    ) throws {
        let provider = try fileSystems.provider(for: directory)
        let listed = directory.appending(name: DescriptIon.fileName)
        var file = try loadForUpdate(directory, cancellation: cancellation)
        let before = file
        if !DescriptIon.normalized(comment).isEmpty, !DescriptIon.canName(name) { throw CommentFileError.unnameable }
        file.setComment(comment, for: name)
        guard file != before else {
            return
        }
        defer { forget(directory) }
        // A comment file that is a link stays one: the file it points to is the one written.
        let url = LocalInfo.isSymlink(listed) ? listed.resolvingSymlinksInPath() : listed
        if file.isEmpty {
            if provider.item(at: listed, cancellation: cancellation) != nil {
                try provider.remove(listed, cancellation: cancellation)
            }
            return
        }
        let wasHidden = LocalInfo.details(url)?.isHidden ?? false
        let existed = provider.item(at: url, cancellation: cancellation) != nil
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        let draft = url.deletingLastPathComponent()
            .appending(
                name: ".\(DescriptIon.fileName).\(UUID().uuidString.prefix(8)).tmp"
            )
        do {
            let writer = try provider.write(draft, cancellation: cancellation)
            do {
                try writer.write(file.data())
                try writer.close(attributes: FileAttributes())
            } catch {
                try? writer.close(attributes: FileAttributes())
                throw error
            }
            // The new file takes the place of the old one and keeps what that one carried
            // besides its text: flags (hidden among them), tags, access rules.
            if existed { try? provider.copyMetadata(from: url, to: draft, cancellation: cancellation) }
            try provider.move(draft, to: url, replacing: true, cancellation: cancellation)
        } catch {
            // Tidying up, without the flag: it may be what ended the writing.
            try? provider.remove(draft)
            throw error
        }
        if hidden || wasHidden, url.isFileURL { try? LocalInfo.setFlag(UInt32(UF_HIDDEN), true, of: url) }
    }
}

enum CommentFileError: LocalizedError {
    case unreadable
    /// The format has no way to write this name so that it reads back as the same name.
    case unnameable

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return
                "The comment file descript.ion cannot be read completely, so it was left as it is. Writing it now would lose its other comments."

        case .unnameable:
            return
                "A name with a line break, or with both a space and a quotation mark, cannot be written to the comment file descript.ion."
        }
    }
}
