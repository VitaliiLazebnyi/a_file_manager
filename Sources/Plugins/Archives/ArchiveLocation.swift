import AFMKernel
import Foundation

/// A place inside an archive: the archive file, on whatever file system it lives (the local
/// disk, a server, another archive), and the path inside it.
struct ArchiveLocation: Equatable {
    /// The archive file itself, as its own file system names it.
    let archive: URL
    /// The path inside, with `/` between the names and none at either end; empty for the
    /// archive's top folder.
    let innerPath: String

    var isRoot: Bool { innerPath.isEmpty }
}

/// The URLs of the archive file systems (spec 08 › Archives as folders).
///
/// The path of such a URL is the path of the archive file followed by the path inside the
/// archive, so everything the panels do with paths (parent, last name, "is inside") works as
/// it does on a disk, and the folder holding the archive is simply further up the same path:
///
///     zip://d3-5f0c2a91/Users/me/photos.zip/2026/beach.jpg
///
/// The host says where the archive ends: `d3` counts the path components that name the archive
/// file, the second part is a check value of that path, and for an archive that is not on the
/// local disk a third part holds, in hexadecimal, the scheme and authority of the URL it has
/// there (`ftp://server`, or the host of an outer archive: archives nest). A URL whose path
/// does not pass through the archive (the check value does not match) is a place on the
/// archive's own file system; the provider hands it on. That happens when the user types a
/// plain path while a panel is inside an archive.
enum ArchiveURL {
    /// Archives whose contents can be changed (ZIP).
    static let writableScheme = "zip"
    /// Everything else: read-only.
    static let readOnlyScheme = "archive"
    static let schemes = [writableScheme, readOnlyScheme]

    enum Place: Equatable {
        case inside(ArchiveLocation)
        /// Not in the archive: a place on the file system the archive lies on.
        case outside(URL)
    }

    static func isArchiveURL(_ url: URL) -> Bool {
        url.scheme.map(schemes.contains) ?? false
    }

    static func make(scheme: String, archive: URL, innerPath: String = "") -> URL {
        let names = pathNames(of: archive)
        let archivePath = "/" + names.joined(separator: "/")
        var host = "d\(names.count)-" + checkValue(archivePath)
        let prefix = authority(of: archive)
        if prefix != "file://" { host += "-" + hex(prefix) }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = innerPath.isEmpty ? archivePath : archivePath + "/" + innerPath
        // Components with a scheme, a host and a path that starts with `/` always make a URL:
        // the path is escaped as it is set, and the host holds letters, digits and `-` only.
        return components.url!
    }

    /// Nil for URLs of other schemes and for hosts this code did not write.
    static func parse(_ url: URL) -> Place? {
        guard isArchiveURL(url), let host = url.host else { return nil }
        let parts = host.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3, parts[0].hasPrefix("d"), let depth = Int(parts[0].dropFirst()),
            depth > 0
        else { return nil }
        let prefix: String
        if parts.count == 3 {
            guard let text = unhex(parts[2]) else { return nil }
            prefix = text
        } else {
            prefix = "file://"
        }
        let names = pathNames(of: url.standardized)
        if names.count >= depth {
            let archivePath = "/" + names[..<depth].joined(separator: "/")
            if checkValue(archivePath) == parts[1], let archive = outerURL(prefix: prefix, path: archivePath) {
                return .inside(ArchiveLocation(archive: archive, innerPath: names[depth...].joined(separator: "/")))
            }
        }
        return outerURL(prefix: prefix, path: "/" + names.joined(separator: "/")).map(Place.outside)
    }

    /// How many archives a location lies inside of: one for a place in an archive on a disk
    /// or a server, two for a place in an archive inside such an archive, and so on.
    static func nesting(of url: URL) -> Int {
        var (depth, current) = (0, url)
        while depth < 64, case .inside(let location)? = parse(current) {
            depth += 1
            current = location.archive
        }
        return depth
    }

    /// The location inside an archive; nil for anything else.
    static func location(of url: URL) -> ArchiveLocation? {
        if case .inside(let location)? = parse(url) { return location }
        return nil
    }

    /// What a URL means outside this plugin: a place that only passes through an archive
    /// scheme becomes the place on the real file system; everything else stays as it is.
    static func resolved(_ url: URL) -> URL {
        if case .outside(let outer)? = parse(url) { return outer }
        return url
    }

    private static func pathNames(of url: URL) -> [String] {
        url.pathComponents.filter { $0 != "/" }
    }

    /// Scheme and authority, e.g. `file://` or `ftp://user@server:21`.
    private static func authority(of url: URL) -> String {
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: true) {
            components.path = ""
            components.query = nil
            components.fragment = nil
            if let text = components.string, text.contains("://") {
                return text
            }
        }
        return (url.scheme ?? "file") + "://"
    }

    private static func outerURL(prefix: String, path: String) -> URL? {
        if prefix == "file://" { return URL(fileURLWithPath: path, isDirectory: false) }
        guard var components = URLComponents(string: prefix) else { return nil }
        components.path = path
        return components.url
    }

    /// FNV-1a over the archive's path: enough to tell "this path runs through the archive"
    /// from "this path is somewhere else".
    private static func checkValue(_ path: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in path.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return String(format: "%08x", hash)
    }

    private static func hex(_ text: String) -> String {
        text.utf8.map { String(format: "%02x", $0) }.joined()
    }

    private static func unhex(_ text: String) -> String? {
        guard text.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}

/// The kinds of archive the plugin knows (spec 08 › Format support matrix).
enum ArchiveFormat: Equatable {
    /// A compressor that wraps one stream of bytes.
    enum Codec: String, Equatable {
        case gzip, bzip2, xz
    }

    case zip
    case tar
    /// A TAR archive inside a compressed stream (`.tar.gz`, `.tgz`, …).
    case compressedTar(Codec)
    /// One compressed file (`.gz`, `.bz2`, `.xz`), shown as a folder with that file in it.
    case compressedFile(Codec)
    /// Anything else the system's `bsdtar` can read: 7z, rar, iso, cab, cpio, xar, …
    case foreign

    /// Whether members can be added, renamed and deleted in place.
    var isEditable: Bool { self == .zip }

    var title: String {
        switch self {
        case .zip: return "ZIP"
        case .tar: return "TAR"
        case .compressedTar(let codec): return "TAR." + Self.suffix(codec).uppercased()
        case .compressedFile(let codec): return Self.suffix(codec).uppercased()
        case .foreign: return "archive"
        }
    }

    static func suffix(_ codec: Codec) -> String {
        switch codec {
        case .gzip: return "gz"
        case .bzip2: return "bz2"
        case .xz: return "xz"
        }
    }

    /// The formats Pack can create, in the order of the dialog.
    static let writable: [Self] = [
        .zip, .tar, .compressedTar(.gzip), .compressedTar(.bzip2), .compressedTar(.xz),
        .compressedFile(.gzip), .compressedFile(.bzip2), .compressedFile(.xz)
    ]

    /// The extension a new archive of this format gets.
    var defaultExtension: String {
        switch self {
        case .zip: return "zip"
        case .tar: return "tar"
        case .compressedTar(let codec): return "tar." + Self.suffix(codec)
        case .compressedFile(let codec): return Self.suffix(codec)
        case .foreign: return ""
        }
    }

    /// Every way a file of this format may end, longest first.
    var extensions: [String] {
        switch self {
        case .zip: return ["zip"]
        case .tar: return ["tar"]
        case .compressedTar(.gzip): return ["tar.gz", "tgz", "taz"]
        case .compressedTar(.bzip2): return ["tar.bz2", "tbz2", "tbz"]
        case .compressedTar(.xz): return ["tar.xz", "txz"]
        case .compressedFile(let codec): return [Self.suffix(codec)]
        case .foreign: return []
        }
    }

    /// The prefix of a Pack target (`tgz:/path/name`), spec 08 › Target string.
    var prefix: String {
        switch self {
        case .compressedTar(.gzip): return "tgz"
        case .compressedTar(.bzip2): return "tbz"
        case .compressedTar(.xz): return "txz"
        default: return defaultExtension
        }
    }

    /// Splits a name into what is in front of a known archive ending and that ending:
    /// `backup.tar.gz` → (`backup`, `tar.gz`). Nil when the name does not end like an archive
    /// that Pack can write.
    static func splitKnownExtension(_ name: String) -> (base: String, ext: String)? {
        let lower = name.lowercased()
        let endings = writable.flatMap(\.extensions).sorted { $0.count > $1.count }
        for ending in endings where lower.hasSuffix("." + ending) && lower.count > ending.count + 1 {
            return (String(name.dropLast(ending.count + 1)), ending)
        }
        return nil
    }

    /// Looks at the first bytes of a file. `tarInside` is asked only for compressed streams:
    /// whether what they hold starts like a TAR archive.
    static func detect(head: Data, name: String, tarInside: (Codec) -> Bool) -> Self {
        let bytes = [UInt8](head.prefix(512))
        func starts(_ signature: [UInt8]) -> Bool {
            bytes.count >= signature.count && Array(bytes[..<signature.count]) == signature
        }
        let lower = name.lowercased()
        if starts([0x50, 0x4B, 0x03, 0x04]) || starts([0x50, 0x4B, 0x05, 0x06]) || starts([0x50, 0x4B, 0x07, 0x08]) {
            return .zip
        }
        let codec: Codec? =
            starts([0x1F, 0x8B])
            ? .gzip
            : starts([0x42, 0x5A, 0x68])
                ? .bzip2
                : starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) ? .xz : nil
        if let codec { return tarInside(codec) ? .compressedTar(codec) : .compressedFile(codec) }
        if TarHeader.looksLikeHeader(head) { return .tar }
        // A ZIP with something in front of it (a self-extracting program) has its directory at the end as usual.
        if lower.hasSuffix(".zip") { return .zip }
        return .foreign
    }
}

/// Which files are handed to a tool of the system to be read, and to which.
///
/// `bsdtar` reads every format libarchive knows, and one of them ("mtree") is a plain text
/// list of files *on this disk* to take the contents from: left to choose for itself, bsdtar
/// would turn a text file that is merely named like an archive into a copy of whatever local
/// files it names. So it is given only files that carry the signature of a format from the
/// list below, and that have a zero byte in their first line: a file with one is never taken
/// for a list by libarchive (tried with the system's bsdtar), whatever else it holds.
/// Compressed streams are not on the list, because the stream inside may be anything.
enum ForeignArchive {
    enum Kind {
        /// 7z, RAR, CAB, XAR, cpio, ISO 9660, LHA: read through `bsdtar`.
        case libarchive
        /// The old `compress` format (`.Z`): unpacked by `gzip`, and read here if it holds a TAR.
        case compressedTar
    }

    static func kind(of file: RandomAccessFile) -> Kind? {
        guard let head = try? file.read(at: 0, count: 512), head.count >= 8 else { return nil }
        let bytes = [UInt8](head)
        func starts(_ signature: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + signature.count && Array(bytes[offset..<(offset + signature.count)]) == signature
        }
        if starts([0x1F, 0x9D]) { return .compressedTar }
        var known =
            starts([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])  // 7z
            || starts([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07])  // RAR 4 and 5
            || starts([0x4D, 0x53, 0x43, 0x46, 0, 0, 0, 0])  // CAB
            || starts([0x78, 0x61, 0x72, 0x21])  // XAR
            || starts(Array("070707".utf8)) || starts(Array("070701".utf8)) || starts(Array("070702".utf8))  // cpio, text headers
            || starts([0xC7, 0x71]) || starts([0x71, 0xC7])  // cpio, binary headers
        // LHA: "-lh5-", "-lzs-", "-pm0-" behind two bytes.
        if !known, bytes[2] == 0x2D, bytes[6] == 0x2D,
            [[0x6C, 0x68], [0x6C, 0x7A], [0x70, 0x6D]].contains(Array(bytes[3..<5]))
        {
            known = true
        }
        if !known {
            // ISO 9660: "CD001" at the start of a volume descriptor, 32 KB into the image.
            for sector in [16, 17, 18] where !known {
                known = (try? file.read(at: UInt64(sector) * 2_048 + 1, count: 5)) == Data("CD001".utf8)
            }
        }
        guard known else { return nil }
        let line = bytes.prefix { $0 != 0x0A }
        return line.contains(0) ? .libarchive : nil
    }
}

enum ArchiveError: LocalizedError {
    case notAnArchive(String)
    case damaged(String)
    case unsupported(String)
    case wrongPassword(String)
    case passwordNeeded(String)
    case crcMismatch(String)
    case notFound(String)
    case notADirectory(String)
    case readOnly(String)
    case changedOutside(String)
    case toolFailed(String)
    case noRoom(String)
    /// The temporary folder's volume has no room to spare for a copy of the archive.
    case noScratchRoom(String)
    case nameCollision(String)
    /// Changes that could not be written before the program quit; the text says what became of them.
    case unsaved(String)
    case cancelled
    /// The store has let this archive go; whoever wanted to change it asks the store again.
    /// Never reaches the user.
    case retired

    var errorDescription: String? {
        switch self {
        case .notAnArchive(let name): return "\(name) is not an archive, or its format is not supported."
        case .damaged(let what): return "The archive is damaged: \(what)."
        case .unsupported(let what): return "\(what) is not supported."
        case .wrongPassword(let name): return "Wrong password for \(name)."
        case .passwordNeeded(let name): return "\(name) is encrypted and no password was given."
        case .crcMismatch(let name): return "CRC error in \(name): the data is damaged."
        case .notFound(let path): return "\(path) does not exist in the archive."
        case .notADirectory(let path): return "\(path) is not a folder."
        case .readOnly(let name): return "Archives of this type cannot be changed (\(name))."

        case .changedOutside(let name):
            return "\(name) was changed by another program; the changes made here were not written."

        case .noRoom(let name): return "There is not enough room on the disk to write the changes into \(name)."

        case .noScratchRoom(let name):
            return "There is not enough room on the startup disk to open \(name): it has to be copied there first."

        case .nameCollision(let name):
            return
                "Several files would be stored under the name \(name). Pack with path names, or pack them one by one."

        case .unsaved(let what): return what
        case .toolFailed(let message): return message
        case .cancelled: return "The operation was cancelled."
        case .retired: return "The archive was read again; please repeat the operation."
        }
    }
}
