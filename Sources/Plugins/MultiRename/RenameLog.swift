import AFMKernel
import Foundation

/// The result log (spec 19 › Multi-Rename result log): one line per renamed file, the old
/// full path and the new name, both quoted and joined by ` -> `.
internal enum RenameLog {
    /// The name of the log file in its folder.
    internal static let fileName = "renlog.txt"

    /// Writes the log where only the user can read it: a folder and a file of their own, never
    /// one in a place that others can write to.
    internal static func write(_ renamed: [RenamedItem], to url: URL, fileSystems: FileSystemRegistry) {
        let manager = FileManager.default
        try? manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard (try? Data(text(renamed, fileSystems: fileSystems).utf8).write(to: url, options: .atomic)) != nil else {
            return
        }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The lines of the log, each with its line end.
    internal static func text(_ renamed: [RenamedItem], fileSystems: FileSystemRegistry) -> String {
        renamed.map { item -> String in
            // A file that moved into another folder is logged with its path from the old one.
            let oldFolder = item.from.deletingLastPathComponent()
            let newName =
                item.destination.deletingLastPathComponent().isSameLocation(as: oldFolder)
                ? item.destination.lastPathComponent
                : item.destination.isInside(oldFolder)
                    ? String(item.destination.path.dropFirst(oldFolder.path.count).drop { $0 == "/" })
                    : fileSystems.displayPath(item.destination)
            return "\"\(fileSystems.displayPath(item.from))\" -> \"\(newName)\"\n"
        }
        .joined()
    }
}
