import AFMKernel
import Foundation

/// What a download list would do, worked out before anything is done: the lines as transfers
/// between two locations, and the lines that are not carried out.
///
/// Main thread; it only reads text (no server and no disk is asked).
internal struct ListPlan {
    /// What a line does with its file.
    internal enum Kind {
        /// Copies to another place, also from this Mac to a server.
        case copy
        /// Fetches from a server to this Mac.
        case download
        /// Copies, then removes the source.
        case move
    }

    /// A line that is carried out.
    internal struct Step {
        /// What is done.
        internal let kind: Kind
        /// The location of the file the line names.
        internal let source: URL
        /// Where the file goes, with the name it is to have there.
        internal let destination: URL
        /// As the user is shown it.
        internal let text: String
    }

    /// One thing to do, in the order of the list.
    internal enum Item {
        /// Waits this many seconds before the next line.
        case pause(TimeInterval)
        /// Copies or moves a file.
        case transfer(Step)
    }

    /// At most this many lines are shown in a message; a list may have a hundred thousand.
    internal static let shownLines = 20

    /// What the list does, in its order.
    internal private(set) var items: [Item] = []
    /// The lines that are not carried out, each with the reason.
    internal private(set) var skipped: [String] = []

    /// The transfers of the list, without its pauses.
    internal var steps: [Step] {
        items.compactMap { item in
            if case .transfer(let step) = item {
                return step
            }
            return nil
        }
    }

    /// True when a line sends away, moves or copies a file that is on this Mac: more than a
    /// download list is expected to do.
    internal var touchesLocalFiles: Bool { steps.contains { $0.kind != .download } }

    /// The plan of `actions`, whose locations are read by `fileSystems`; a relative one lies below `base`, which is
    /// also where a line without a target puts its file.
    internal init(actions: [DownloadList.Action], base: URL, fileSystems: FileSystemRegistry) {
        for action in actions {
            switch action {
            case .pause(let seconds):
                items.append(.pause(seconds))

            case .unsupported(let line):
                skipped.append(line)

            case .download(let source, let target):
                add(.download, from: source, to: target, base: base, fileSystems: fileSystems)

            case .copy(let source, let target):
                add(.copy, from: source, to: target, base: base, fileSystems: fileSystems)

            case .move(let source, let target):
                add(.move, from: source, to: target, base: base, fileSystems: fileSystems)
            }
        }
    }

    /// `lines` as a message shows them: the first `shownLines`, each cut at 300 characters, and how many more.
    internal static func shortened(_ lines: [String]) -> String {
        let shown = lines.prefix(shownLines).map { $0.count > 300 ? String($0.prefix(300)) + "…" : $0 }
        return (shown + (lines.count > shownLines ? ["… and \(lines.count - shownLines) more"] : []))
            .joined(separator: "\n")
    }

    /// What the user is asked to agree to before the list runs.
    internal func preview(of list: URL) -> (message: String, detail: String) {
        let all = steps
        let downloads = all.filter { $0.kind == .download }.count
        let moves = all.filter { $0.kind == .move }.count
        let copies = all.count - downloads - moves
        var counts: [String] = []
        if downloads > 0 { counts.append("\(downloads) downloads") }
        if copies > 0 { counts.append("\(copies) uploads or copies") }
        if moves > 0 { counts.append("\(moves) moves") }
        var detail = "\(list.path) says:\n\n" + Self.shortened(all.map(\.text))
        if touchesLocalFiles {
            detail +=
                "\n\nThis list does more than download: it sends, copies or moves files that are on this Mac"
                + (moves > 0 ? ", and a move deletes its source" : "")
                + ". Run it only if you wrote it or know who did."
        }
        if !skipped.isEmpty { detail += "\n\n\(skipped.count) lines will not be carried out." }
        detail += "\n\nYou are asked before a file that exists is replaced."
        return ("Run this download list? (\(counts.joined(separator: ", ")))", detail)
    }

    /// Adds the line that does `kind` from `source` to `target` (nil: into `base`), or puts it among the skipped
    /// lines when it is a plain line that does not fetch from a server to this Mac.
    private mutating func add(
        _ kind: Kind,
        from source: String,
        to target: String?,
        base: URL,
        fileSystems: FileSystemRegistry
    ) {
        let origin = fileSystems.location(from: source, relativeTo: base)
        let destination =
            target.map { fileSystems.location(from: $0, relativeTo: base) }
            ?? base.appending(name: origin.lastPathComponent)
        // Both have a file system: a location written out in full is one of a registered file
        // system (the registry reads it), anything else lies below `base`.
        // A plain line fetches from a server to this Mac. Anything else must say so (`put:`, `copy:`, `move:`).
        if kind == .download, origin.isFileURL || !destination.isFileURL {
            skipped.append(
                "\(source) (not a download from a server to this Mac; such a line must start with put:, copy: or "
                    + "move:)"
            )
            return
        }
        let verb =
            kind == .move
            ? "Move (the source is deleted)"
            : kind == .copy ? (origin.isFileURL && !destination.isFileURL ? "Upload" : "Copy") : "Download"
        let shown = "\(verb): \(fileSystems.displayPath(origin))  →  \(fileSystems.displayPath(destination))"
        items.append(.transfer(Step(kind: kind, source: origin, destination: destination, text: shown)))
    }
}
