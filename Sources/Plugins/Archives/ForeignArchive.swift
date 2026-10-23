import Foundation

/// Which files are handed to a tool of the system to be read, and to which.
///
/// `bsdtar` reads every format libarchive knows, and one of them ("mtree") is a plain text
/// list of files *on this disk* to take the contents from: left to choose for itself, bsdtar
/// would turn a text file that is merely named like an archive into a copy of whatever local
/// files it names. So it is given only files that carry the signature of a format from the
/// list below, and that have a zero byte in their first line: a file with one is never taken
/// for a list by libarchive (tried with the system's bsdtar), whatever else it holds.
/// Compressed streams are not on the list, because the stream inside may be anything.
internal enum ForeignArchive {
    /// The tool a foreign archive goes to.
    internal enum Kind {
        /// The old `compress` format (`.Z`): unpacked by `gzip`, and read here if it holds a TAR.
        case compressedTar
        /// 7z, RAR, CAB, XAR, cpio, ISO 9660, LHA: read through `bsdtar`.
        case libarchive
    }

    /// The tool that may read the file, judged by its first bytes; nil for a file no tool is given.
    internal static func kind(of file: RandomAccessFile) -> Kind? {
        guard let head = try? file.read(at: 0, count: 512), head.count >= 8 else {
            return nil
        }
        let bytes = [UInt8](head)
        func starts(_ signature: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + signature.count && Array(bytes[offset..<(offset + signature.count)]) == signature
        }
        if starts([0x1F, 0x9D]) {
            return .compressedTar
        }
        // cpio comes with text headers (070707, 070701, 070702) or binary ones.
        var known =
            starts([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])  // 7z
            || starts([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07])  // RAR 4 and 5
            || starts([0x4D, 0x53, 0x43, 0x46, 0, 0, 0, 0])  // CAB
            || starts([0x78, 0x61, 0x72, 0x21])  // XAR
            || starts(Array("070707".utf8)) || starts(Array("070701".utf8)) || starts(Array("070702".utf8))
            || starts([0xC7, 0x71]) || starts([0x71, 0xC7])
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
        guard known else {
            return nil
        }
        let line = bytes.prefix { $0 != 0x0A }
        return line.contains(0) ? .libarchive : nil
    }
}
