import AFMKernel
import Foundation

/// The folders of copies: their names, and the sweep of those a crash left behind.
extension TemporaryCopies {
    /// The start of the name of every folder of copies, followed by `p`, the process number and a UUID.
    internal static let prefix = "afm-viewer-"

    /// Once per launch, in the background: removes the folders of processes that are gone (a crash
    /// does not run `deinit`), and those of earlier versions that are over a day old.
    internal static let sweepOnce: Void = {
        BlockingCalls.run { sweep(in: FileManager.default.temporaryDirectory) }
    }()

    /// A file name for a copy: one path component, whatever the name of the file was (it may
    /// be anything a server sent, decoded: `..`, `a/b`, a very long name).
    internal static func safeName(_ name: String) -> String {
        var cleaned = String(
            String.UnicodeScalarView(
                name.unicodeScalars.map { scalar in
                    scalar == "/" || scalar == ":" || scalar == "\\" || scalar.value < 0x20 || scalar.value == 0x7F
                        ? "_" : scalar
                }
            )
        )
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty || cleaned.allSatisfy({ $0 == "." }) {
            return "file"
        }
        // A name is at most 255 bytes: keep the end, which holds the extension that picks the player.
        while cleaned.utf8.count > 200 { cleaned.remove(at: cleaned.index(after: cleaned.startIndex)) }
        return cleaned.first == "." ? "_" + cleaned : cleaned
    }

    /// Removes the folders of copies in `directory` whose process is gone, and those without one that are over a
    /// day old.
    internal static func sweep(in directory: URL) {
        sweep(in: directory, now: Date())
    }

    /// The same, with `now` the time the age of a folder is counted to.
    internal static func sweep(in directory: URL, now: Date) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        for name in names where name.hasPrefix(prefix) {
            let folder = directory.appendingPathComponent(name, isDirectory: true)
            let rest = name.dropFirst(prefix.count)
            if rest.hasPrefix("p"), let pid = Int32(rest.dropFirst().prefix { $0 != "-" }) {
                if pid != getpid(), kill(pid, 0) != 0, errno == ESRCH { try? manager.removeItem(at: folder) }
            } else if let modified = (try? manager.attributesOfItem(atPath: folder.path))?[.modificationDate] as? Date,
                now.timeIntervalSince(modified) > 86_400
            {
                try? manager.removeItem(at: folder)
            }
        }
    }
}
