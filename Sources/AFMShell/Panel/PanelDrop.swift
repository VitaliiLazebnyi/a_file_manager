import AFMContracts
import AFMKernel
import AppKit

/// The rules of dragging files with the mouse (spec 05 › Drag & drop), apart from the views
/// they happen in.
@MainActor
internal enum PanelDrop {
    /// Marks a drag that started in a panel of this program.
    ///
    /// It carries no location, only the ticket of the drag (`PanelDragPayload.token`): what is
    /// dragged stays inside the program (`current`), where items of any file system can be named
    /// and nobody else can put anything. A pasteboard of another program that offers this type is
    /// not believed.
    internal static let itemType = NSPasteboard.PasteboardType("afm.panel-item")
    /// The paths of files as a list, the way programs took files before there were file URLs;
    /// the one form in which a single pasteboard item can name many files.
    nonisolated internal static let fileNamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    /// What the lists take when something is dropped on them.
    internal static let acceptedTypes: [NSPasteboard.PasteboardType] = [itemType, .fileURL]
    /// Up to this many dragged items each get a pasteboard item of their own, which is what other
    /// programs expect of a drag of several files.
    ///
    /// A larger drag (making a hundred thousand pasteboard items takes a third of a second and
    /// more) travels as one item that hands out its files only when a program asks for them.
    nonisolated internal static let itemsWrittenSingly = 2_000

    /// The drag of this program that is under way, from its start to its end.
    internal private(set) static var current: PanelDragPayload?
    /// What a drag over a panel carries, read once per drag and shared by both panels.
    internal private(set) static var session: DropSession?

    /// A drag of what `payload` carries starts: what goes on the pasteboard for it.
    ///
    /// The first item carries the ticket. Items of the local disks are also there for other
    /// programs: each as a file URL of its own while they are few, otherwise all through the first
    /// item, on demand (and, once the items are on the drag's pasteboard, as a list:
    /// `offerFileNames`). Nothing for an empty drag.
    internal static func beginDrag(_ payload: PanelDragPayload) -> [NSPasteboardItem] {
        guard payload.itemCount > 0 else {
            return []
        }
        current = payload
        let first = NSPasteboardItem()
        first.setString(payload.token, forType: itemType)
        guard !payload.isWrittenLazily else {
            first.setDataProvider(payload, forTypes: [.fileURL])
            return [first]
        }
        var written = [first]
        for (index, item) in payload.items.enumerated() {
            let entry = index == 0 ? first : NSPasteboardItem()
            if item.url.isFileURL {
                entry.setString(item.url.absoluteString, forType: .fileURL)
            }
            // An item no other program can read still keeps its place, so the items count right.
            if index > 0 {
                if !item.url.isFileURL {
                    entry.setString("", forType: itemType)
                }
                written.append(entry)
            }
        }
        return written
    }

    /// For a drag of very many items, whose pasteboard holds one item only: offers the files as a
    /// list of paths as well, made when a program asks for it.
    ///
    /// Called when the items of `beginDrag` are on the drag's pasteboard.
    internal static func offerFileNames(on pasteboard: NSPasteboard) {
        guard let current, current.isWrittenLazily else {
            return
        }
        pasteboard.addTypes([fileNamesType], owner: current)
    }

    /// The drag is over, wherever it ended.
    internal static func endDrag() {
        current = nil
    }

    /// The items a drag carries: those of a panel of this program, or files from Finder and other
    /// programs.
    ///
    /// The panel's own type is taken only from the program's own drag: its ticket has to be the one
    /// of the drag under way. Anything else is read for local files only, so no other program can
    /// make a panel name a server or an archive as a source.
    internal static func locations(on pasteboard: NSPasteboard) -> [URL] {
        if let own = ownPayload(on: pasteboard) {
            return own.locations
        }
        // The class pasteboards read URLs as, which also turns the file references other
        // programs write into URLs.
        let classes: [AnyClass] = [URL._ObjectiveCType.self]
        // `readObjects` answers nil, which names no file, for a pasteboard it cannot read.
        let read = [pasteboard.readObjects(forClasses: classes, options: [.urlReadingFileURLsOnly: true])]
        // The option keeps out what is not written as a file URL, but not a server or an archive
        // written in the file URL's type: only file URLs are taken.
        return read.compactMap(\.self).joined().compactMap { $0 as? URL }.filter(\.isFileURL)
    }

    /// What the drag `info` carries, read the first time a panel asks during the drag.
    internal static func session(for info: any NSDraggingInfo) -> DropSession {
        if let session, session.sequence == info.draggingSequenceNumber {
            return session
        }
        let read: DropSession
        if let own = ownPayload(on: info.draggingPasteboard) {
            // The program's own drag may still be putting its items together.
            read = DropSession(sequence: info.draggingSequenceNumber, payload: own)
        } else {
            read = DropSession(
                sequence: info.draggingSequenceNumber,
                sources: locations(on: info.draggingPasteboard)
            )
        }
        session = read
        return read
    }

    /// Lets go of what was read of the drag `sequence` (of any drag, for nil): it ended, or
    /// left for good.
    internal static func endSession(_ sequence: Int?) {
        if sequence == nil || session?.sequence == sequence {
            session = nil
        }
    }

    /// A drag left a list.
    ///
    /// What was read of another program's drag is not kept while it is elsewhere; the program's own
    /// drag stays known until it ends.
    internal static func dragLeft(_ info: (any NSDraggingInfo)?) {
        if current == nil {
            endSession(info?.draggingSequenceNumber)
        }
    }

    /// What a drop does: a copy between volumes and a move inside one, as in Finder; Option asks
    /// for a copy and Cmd for a move.
    ///
    /// Nothing when the source of the drag does not allow it.
    internal static func kind(modifiers: NSEvent.ModifierFlags, sameVolume: Bool, allowed: NSDragOperation)
        -> TransferKind?
    {
        let canMove = allowed.contains(.move) || allowed.contains(.generic)
        // What is wanted, the first choice first.
        let wanted: [TransferKind] =
            if modifiers.contains(.option) {
                [.copy]
            } else if modifiers.contains(.command) {
                [.move]
            } else {
                sameVolume ? [.move, .copy] : [.copy, .move]
            }
        return wanted.first { $0 == .move ? canMove : allowed.contains(.copy) }
    }

    /// Where the volumes of the local file system are mounted.
    ///
    /// The system answers this from what it has in memory, without asking any disk or server, so it
    /// may be called on the main thread.
    internal static func mountPoints() -> [String] {
        Mounts.volumes().map(\.path)
    }

    /// The mount point a local path lies below: the longest one that is a prefix of it.
    internal static func mountPoint(of path: String, among mountPoints: [String]) -> String {
        mountPoints.filter { $0 == "/" || path == $0 || path.hasPrefix($0 + "/") }.max { $0.count < $1.count } ?? "/"
    }

    /// Whether two locations are on the same volume, judged by their writing alone.
    ///
    /// Two places of another file system count as one volume when they are on the same server.
    internal static func areOnSameVolume(_ first: URL, _ second: URL, mountPoints: [String]) -> Bool {
        guard first.isFileURL, second.isFileURL else {
            return (first.scheme, first.host, first.port) == (second.scheme, second.host, second.port)
        }
        return mountPoint(of: first.path, among: mountPoints) == mountPoint(of: second.path, among: mountPoints)
    }

    /// The question a drop asks before it starts, when the user wants to be asked
    /// (spec 05 › Drag & drop, Confirmation).
    internal static func question(_ kind: TransferKind, count: Int) -> String {
        "\(kind == .move ? "Move" : "Copy") \(count) item\(count == 1 ? "" : "s") to"
    }

    /// The program's own drag, when this pasteboard is its: the ticket on it has to be the
    /// one of the drag under way.
    private static func ownPayload(on pasteboard: NSPasteboard) -> PanelDragPayload? {
        guard let current, let ticket = pasteboard.pasteboardItems?.first?.string(forType: itemType),
            ticket == current.token
        else {
            return nil
        }
        return current
    }
}
