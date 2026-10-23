import Foundation

/// The kinds of archive the plugin knows (spec 08 › Format support matrix).
internal enum ArchiveFormat: Equatable {
    /// One compressed file (`.gz`, `.bz2`, `.xz`), shown as a folder with that file in it.
    case compressedFile(Codec)
    /// A TAR archive inside a compressed stream (`.tar.gz`, `.tgz`, …).
    case compressedTar(Codec)
    /// Anything else the system's `bsdtar` can read: 7z, rar, iso, cab, cpio, xar, …
    case foreign
    /// A plain TAR archive, read and written here.
    case tar
    /// A ZIP archive, the one format whose members can be changed in place.
    case zip

    /// A compressor that wraps one stream of bytes.
    internal enum Codec: Equatable {
        /// bzip2 (`.bz2`), through the system's `bzip2` tool.
        case bzip2
        /// gzip (`.gz`), deflate through zlib.
        case gzip
        /// XZ (`.xz`): LZMA in the XZ container, through the Compression framework.
        case xzStream
    }

    /// The formats Pack can create, in the order of the dialog.
    internal static let writable: [Self] = [
        .zip, .tar, .compressedTar(.gzip), .compressedTar(.bzip2), .compressedTar(.xzStream),
        .compressedFile(.gzip), .compressedFile(.bzip2), .compressedFile(.xzStream)
    ]

    /// Whether members can be added, renamed and deleted in place.
    internal var isEditable: Bool { self == .zip }

    /// The name of the format as the user sees it: `ZIP`, `TAR.GZ`, `XZ`, or "archive" for a foreign one.
    internal var title: String {
        switch self {
        case .zip:
            return "ZIP"

        case .tar:
            return "TAR"

        case .compressedTar(let codec):
            return "TAR." + Self.suffix(codec).uppercased()

        case .compressedFile(let codec):
            return Self.suffix(codec).uppercased()

        case .foreign:
            return "archive"
        }
    }

    /// The extension a new archive of this format gets.
    internal var defaultExtension: String {
        switch self {
        case .zip:
            return "zip"

        case .tar:
            return "tar"

        case .compressedTar(let codec):
            return "tar." + Self.suffix(codec)

        case .compressedFile(let codec):
            return Self.suffix(codec)

        case .foreign:
            return ""
        }
    }

    /// Every way a file of this format may end, longest first.
    internal var extensions: [String] {
        switch self {
        case .zip:
            return ["zip"]

        case .tar:
            return ["tar"]

        case .compressedTar(.gzip):
            return ["tar.gz", "tgz", "taz"]

        case .compressedTar(.bzip2):
            return ["tar.bz2", "tbz2", "tbz"]

        case .compressedTar(.xzStream):
            return ["tar.xz", "txz"]

        case .compressedFile(let codec):
            return [Self.suffix(codec)]

        case .foreign:
            return []
        }
    }

    /// The prefix of a Pack target (`tgz:/path/name`), spec 08 › Target string.
    internal var prefix: String {
        switch self {
        case .compressedTar(.gzip):
            return "tgz"

        case .compressedTar(.bzip2):
            return "tbz"

        case .compressedTar(.xzStream):
            return "txz"

        default:
            return defaultExtension
        }
    }

    /// The file extension of a stream compressed with `codec`, without the dot: `gz`, `bz2` or `xz`.
    internal static func suffix(_ codec: Codec) -> String {
        switch codec {
        case .gzip:
            return "gz"

        case .bzip2:
            return "bz2"

        case .xzStream:
            return "xz"
        }
    }

    /// Splits a name into what is in front of a known archive ending and that ending:
    /// `backup.tar.gz` → (`backup`, `tar.gz`).
    ///
    /// Nil when the name does not end like an archive that Pack can write.
    internal static func splitKnownExtension(_ name: String) -> (base: String, ext: String)? {
        let lower = name.lowercased()
        let endings = writable.flatMap(\.extensions).sorted { $0.count > $1.count }
        for ending in endings where lower.hasSuffix("." + ending) && lower.count > ending.count + 1 {
            return (String(name.dropLast(ending.count + 1)), ending)
        }
        return nil
    }

    /// Looks at the first bytes of a file. `tarInside` is asked only for compressed streams:
    /// whether what they hold starts like a TAR archive.
    internal static func detect(head: Data, name: String, tarInside: (Codec) -> Bool) -> Self {
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
                : starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) ? .xzStream : nil
        if let codec {
            return tarInside(codec) ? .compressedTar(codec) : .compressedFile(codec)
        }
        if TarHeader.looksLikeHeader(head) {
            return .tar
        }
        // A ZIP with something in front of it (a self-extracting program) has its directory at the end as usual.
        if lower.hasSuffix(".zip") {
            return .zip
        }
        return .foreign
    }
}
