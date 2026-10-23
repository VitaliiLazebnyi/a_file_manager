import AFMKernel
import Foundation

/// Creates links on the Mac's own file system.
///
/// Blocks; for a job's thread.
internal enum LinkMaker {
    /// Creates a link at `destination` that leads to `source`.
    ///
    /// An existing item at the destination is never replaced. `relative` writes a symbolic link's
    /// target relative to the link's own folder, so the pair can be moved together.
    internal static func create(_ kind: LinkKind, to source: URL, at destination: URL, relative: Bool) throws {
        guard source.isFileURL, destination.isFileURL else { throw FileSystemError.notSupported("Creating links") }
        var existing = stat()
        if lstat(destination.path, &existing) == 0 { throw FileSystemError.alreadyExists(destination.path) }
        switch kind {
        case .symbolic:
            let target =
                relative ? relativePath(from: destination.deletingLastPathComponent(), to: source) : source.path
            if symlink(target, destination.path) != 0 { throw LocalInfo.posixError(errno, destination) }

        case .hard:
            if link(source.path, destination.path) != 0 { throw LocalInfo.posixError(errno, destination) }

        case .alias:
            let bookmark = try source.bookmarkData(
                options: .suitableForBookmarkFile,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            try URL.writeBookmarkData(bookmark, to: destination)
        }
    }

    /// The path that leads from `directory` to `target`: `../B/file.txt`.
    internal static func relativePath(from directory: URL, to target: URL) -> String {
        let start = directory.standardizedFileURL.pathComponents
        let end = target.standardizedFileURL.pathComponents
        var common = 0
        while common < start.count, common < end.count, start[common] == end[common] { common += 1 }
        let steps = Array(repeating: "..", count: start.count - common) + end[common...]
        return steps.isEmpty ? "." : steps.joined(separator: "/")
    }
}
