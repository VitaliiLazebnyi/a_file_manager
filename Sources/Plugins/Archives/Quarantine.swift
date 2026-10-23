import Foundation

/// The mark the system puts on files that came from the internet (`com.apple.quarantine`).
///
/// What is unpacked from a marked archive is marked the same way, as the system's own unpacker
/// does, so that a program from such an archive is still checked when it is first opened.
internal enum Quarantine {
    private static let name = "com.apple.quarantine"

    /// The mark of the file at `path`; nil when it has none.
    ///
    /// Read in one call: the mark is a short line of text, which a buffer of 4 KB holds with room
    /// to spare.
    internal static func read(_ path: String) -> Data? {
        var value = Data(count: 4_096)
        let got = value.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, $0.count, 0, 0) }
        return got > 0 ? value.prefix(got) : nil
    }

    /// Marks a file or folder on the local disk; other places cannot carry the mark.
    internal static func apply(_ value: Data?, to url: URL) {
        guard let value, url.isFileURL else {
            return
        }
        _ = value.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
    }
}
