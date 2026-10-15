import AFMKernel
import Foundation

/// What the benchmarks work on: names and lists made the same way every time, and a folder and
/// an archive on the disk that are made once and kept in `.build-tools/bench`.
internal enum Fixtures {
    /// The folder that keeps what is made on the disk between runs.
    internal static let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build-tools/bench", isDirectory: true)

    /// Shapes of names as folders hold them: camera pictures, documents, names with accents
    /// written either way, Cyrillic, names without an extension, hidden names, numbered copies.
    private static let shapes: [(String, String)] = [
        ("IMG_", ".JPG"), ("report-", ".pdf"), ("\u{414}\u{43E}\u{43A}\u{443}\u{43C}\u{435}\u{43D}\u{442} ", ".docx"),
        ("e\u{301}te\u{301} ", ".txt"), ("\u{E9}t\u{E9} ", ".txt"), ("file", ""), (".hidden", ".plist"),
        ("Copy of notes (", ").md"), ("archive_", ".tar.gz"), ("Song ", ".m4a")
    ]

    /// The `index`th name: of a shape chosen by a mixed number, with a number in it.
    internal static func name(_ index: Int) -> String {
        let mixed = UInt64(truncatingIfNeeded: index) &* 0x9E37_79B9_7F4A_7C15
        let (prefix, suffix) = shapes[Int(mixed >> 60) % shapes.count]
        return "\(prefix)\((mixed >> 40) % 1_000_000)\(suffix)"
    }

    /// `count` entries of a folder, one in twenty a folder, with sizes and dates that repeat.
    internal static func items(_ count: Int) -> [FileItem] {
        let base = URL(fileURLWithPath: "/bench", isDirectory: true)
        return (0..<count)
            .map { index in
                let name = name(index)
                return FileItem(
                    url: base.appending(name: name),
                    name: name,
                    kind: .init(isDirectory: index.isMultiple(of: 20)),
                    stat: .init(
                        size: Int64(index % 10_000) * 1_024,
                        modified: Date(timeIntervalSinceReferenceDate: Double(index % 5_000) * 3_600)
                    )
                )
            }
    }

    /// A folder on the disk with `count` empty files, made once.
    internal static func localFolder(_ count: Int) throws -> URL {
        let url = folder.appendingPathComponent("folder-\(count)", isDirectory: true)
        let done = folder.appendingPathComponent("folder-\(count).done")
        guard !FileManager.default.fileExists(atPath: done.path) else {
            return url
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for index in 0..<count {
            FileManager.default.createFile(atPath: url.appending(name: "\(index) \(name(index))").path, contents: nil)
        }
        FileManager.default.createFile(atPath: done.path, contents: nil)
        return url
    }

    /// A ZIP archive of the folder of `count` files (stored, not compressed), made once with the
    /// system's `zip`.
    internal static func archive(_ count: Int) throws -> URL {
        let url = folder.appendingPathComponent("entries-\(count).zip")
        guard !FileManager.default.fileExists(atPath: url.path) else {
            return url
        }
        let source = try localFolder(count)
        let partial = url.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = source.deletingLastPathComponent()
        zip.arguments = ["-q", "-r", "-0", partial.path, source.lastPathComponent]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.moveItem(at: partial, to: url)
        return url
    }
}
