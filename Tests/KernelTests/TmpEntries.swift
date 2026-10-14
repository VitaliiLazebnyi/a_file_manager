import AFMKernel
import Foundation

/// Entries in `/tmp` made up on the spot, for the sorting and panel model tests.
///
/// Only the name, the kind, the size and the date matter; nothing is read from the disk.
internal enum TmpEntries {
    /// Three hundred entries: every tenth the folder `folder<n>`, the others the file
    /// `file<n>.txt` of 3 × n bytes.
    internal static var numbered: [FileItem] {
        (0..<300)
            .map { number -> FileItem in
                let isFolder = number.isMultiple(of: 10)
                return make(
                    isFolder ? "folder\(number)" : "file\(number).txt",
                    folder: isFolder,
                    size: Int64(number * 3),
                    time: 0
                )
            }
    }

    /// The entry `/tmp/<name>`: a folder or a file of `size` bytes, changed `time` seconds after 1970.
    internal static func make(_ name: String, folder: Bool, size: Int64, time: TimeInterval) -> FileItem {
        FileItem(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            name: name,
            kind: .init(isDirectory: folder),
            stat: .init(size: size, modified: Date(timeIntervalSince1970: time))
        )
    }
}
