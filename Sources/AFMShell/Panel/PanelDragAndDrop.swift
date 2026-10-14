import AFMContracts
import AFMKernel
import AppKit

/// The rules of dragging files with the mouse (spec 05 › Drag & drop), apart from the views
/// they happen in.
enum PanelDrop {
    /// Marks a drag that started in a panel of this program. It carries no location, only
    /// the ticket of the drag (`Payload.token`): what is dragged stays inside the program
    /// (`current`), where items of any file system can be named and nobody else can put
    /// anything. A pasteboard of another program that offers this type is not believed.
    static let itemType = NSPasteboard.PasteboardType("afm.panel-item")
    /// The paths of files as a list, the way programs took files before there were file URLs;
    /// the one form in which a single pasteboard item can name many files.
    static let fileNamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    static let acceptedTypes: [NSPasteboard.PasteboardType] = [itemType, .fileURL]

    /// Up to this many dragged items each get a pasteboard item of their own, which is what
    /// other programs expect of a drag of several files. A larger drag (making a hundred
    /// thousand pasteboard items takes a third of a second and more) travels as one item that
    /// hands out its files only when a program asks for them.
    static let itemsWrittenSingly = 2_000

    /// What a drag that started in a panel carries. Main thread only.
    ///
    /// A drag of a few items holds them from the start. A drag of very many marked items
    /// starts with the marks alone (`PanelModel.Operands`, which costs nothing to take): the
    /// list of the items and of their locations is put together in the background while the
    /// drag is already under way, and whoever needs it before that (a drop a moment after the
    /// start, another program asking for the files) has it put together then and there.
    final class Payload: NSObject, NSPasteboardItemDataProvider, NSPasteboardTypeOwner {
        let token = UUID().uuidString
        /// How many items are dragged.
        let count: Int
        /// The files are handed out on demand, all through the first pasteboard item.
        let isWrittenLazily: Bool
        private var gathered: (items: [FileItem], locations: [URL])?
        private var marks: PanelModel.Operands?
        private var waiting: [([URL]) -> Void] = []

        init(items: [FileItem]) {
            count = items.count
            isWrittenLazily = items.count > PanelDrop.itemsWrittenSingly
            gathered = (items, items.map(\.url))
        }

        /// The marked items of a panel, as `marks` has them; they are many.
        init(marked marks: PanelModel.Operands) {
            count = marks.markedCount
            isWrittenLazily = true
            self.marks = marks
            super.init()
            Background.compute(
                work: { () -> (items: [FileItem], locations: [URL]) in
                    let items = marks.markedItems()
                    return (items, items.map(\.url))
                }, then: { [weak self] gathered in self?.take(gathered) })
        }

        private func take(_ result: (items: [FileItem], locations: [URL])) {
            guard gathered == nil else { return }
            gathered = result
            marks = nil
            let waiting = waiting
            self.waiting = []
            waiting.forEach { $0(result.locations) }
        }

        /// False while the items are still being put together in the background.
        var isReady: Bool { gathered != nil }

        /// The dragged items; put together here and now if the background has not got there.
        var items: [FileItem] {
            if gathered == nil, let marks {
                let items = marks.markedItems()
                take((items, items.map(\.url)))
            }
            return gathered?.items ?? []
        }

        var locations: [URL] {
            _ = items
            return gathered?.locations ?? []
        }

        /// Calls `receive` with the locations when they are known: now, or when the
        /// background has put them together.
        func whenReady(_ receive: @escaping ([URL]) -> Void) {
            if let gathered { receive(gathered.locations) } else { waiting.append(receive) }
        }

        /// Another program asks for a file: the first one of the local disks.
        func pasteboard(
            _: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType
        ) {
            if type == .fileURL, let first = items.first(where: { $0.url.isFileURL }) {
                item.setString(first.url.absoluteString, forType: .fileURL)
            }
        }

        /// Another program asks for the list of files: only now are their paths put together.
        func pasteboard(_ sender: NSPasteboard, provideDataForType type: NSPasteboard.PasteboardType) {
            guard type == PanelDrop.fileNamesType else { return }
            sender.setPropertyList(items.lazy.filter { $0.url.isFileURL }.map(\.url.path) as [String], forType: type)
        }
    }

    /// The drag of this program that is under way, from its start to its end.
    private(set) static var current: Payload?

    /// A drag of these items starts: what goes on the pasteboard for it. The first item
    /// carries the ticket. Items of the local disks are also there for other programs: each as
    /// a file URL of its own while they are few, otherwise all through the first item, on
    /// demand (and, once the items are on the drag's pasteboard, as a list: `offerFileNames`).
    static func beginDrag(of items: [FileItem]) -> [NSPasteboardItem] {
        guard !items.isEmpty else { return [] }
        return beginDrag(Payload(items: items))
    }

    /// The same for a payload that is made already (the marked items of a long list).
    static func beginDrag(_ payload: Payload) -> [NSPasteboardItem] {
        guard payload.count > 0 else { return [] }
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
            if item.url.isFileURL { entry.setString(item.url.absoluteString, forType: .fileURL) }
            // An item no other program can read still keeps its place, so the items count right.
            if index > 0 {
                if !item.url.isFileURL { entry.setString("", forType: itemType) }
                written.append(entry)
            }
        }
        return written
    }

    /// For a drag of very many items, whose pasteboard holds one item only: offers the files
    /// as a list of paths as well, made when a program asks for it. Called when the items of
    /// `beginDrag` are on the drag's pasteboard.
    static func offerFileNames(on pasteboard: NSPasteboard) {
        guard let current, current.isWrittenLazily else { return }
        pasteboard.addTypes([fileNamesType], owner: current)
    }

    /// The drag is over, wherever it ended.
    static func endDrag() {
        current = nil
    }

    /// The program's own drag, when this pasteboard is its: the ticket on it has to be the
    /// one of the drag under way.
    private static func ownPayload(on pasteboard: NSPasteboard) -> Payload? {
        guard let current, let ticket = pasteboard.pasteboardItems?.first?.string(forType: itemType),
            ticket == current.token
        else { return nil }
        return current
    }

    /// The items a drag carries: those of a panel of this program, or files from Finder and
    /// other programs. The panel's own type is taken only from the program's own drag: its
    /// ticket has to be the one of the drag under way. Anything else is read for local files
    /// only, so no other program can make a panel name a server or an archive as a source.
    static func locations(on pasteboard: NSPasteboard) -> [URL] {
        if let own = ownPayload(on: pasteboard) { return own.locations }
        return pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
            ?? []
    }

    /// What a drag over a panel carries, read once per drag and shared by both panels.
    private static var session: DropSession?

    static func session(for info: NSDraggingInfo) -> DropSession {
        if let session, session.sequence == info.draggingSequenceNumber { return session }
        let session: DropSession
        if let own = ownPayload(on: info.draggingPasteboard) {
            // The program's own drag may still be putting its items together.
            session = DropSession(sequence: info.draggingSequenceNumber, payload: own)
        } else {
            session = DropSession(
                sequence: info.draggingSequenceNumber, sources: locations(on: info.draggingPasteboard))
        }
        self.session = session
        return session
    }

    /// Lets go of what was read of a drag: it ended, or left for good.
    static func endSession(_ sequence: Int? = nil) {
        if sequence == nil || session?.sequence == sequence { session = nil }
    }

    /// True while something read of a drag is kept, for checks.
    static var hasSession: Bool { session != nil }

    /// What a drop does: a copy between volumes and a move inside one, as in Finder; Option
    /// asks for a copy and Cmd for a move. Nothing when the source of the drag does not allow it.
    static func kind(modifiers: NSEvent.ModifierFlags, sameVolume: Bool, allowed: NSDragOperation) -> TransferKind? {
        let wanted: TransferKind
        if modifiers.contains(.option) {
            wanted = .copy
        } else if modifiers.contains(.command) {
            wanted = .move
        } else {
            wanted = sameVolume ? .move : .copy
        }
        let canCopy = allowed.contains(.copy)
        let canMove = allowed.contains(.move) || allowed.contains(.generic)
        switch wanted {
        case .copy: return canCopy ? .copy : (canMove && !modifiers.contains(.option) ? .move : nil)
        case .move: return canMove ? .move : (canCopy && !modifiers.contains(.command) ? .copy : nil)
        }
    }

    /// Whether a drop makes no sense: nothing to drop, a folder into itself or into one of its
    /// own subfolders, or a move of items into the folder they are already in.
    static func isPointless(_ kind: TransferKind, _ sources: [URL], into destination: URL) -> Bool {
        if sources.isEmpty { return true }
        if sources.contains(where: { destination.isSameLocation(as: $0) || destination.isInside($0) }) { return true }
        return kind == .move && sources.allSatisfy { $0.deletingLastPathComponent().isSameLocation(as: destination) }
    }

    /// Where the volumes of the local file system are mounted. The system answers this from
    /// what it has in memory, without asking any disk or server, so it may be called on the
    /// main thread.
    static func mountPoints() -> [String] {
        Mounts.volumes().map(\.path)
    }

    /// The mount point a local path lies below: the longest one that is a prefix of it.
    static func mountPoint(of path: String, among mountPoints: [String]) -> String {
        mountPoints.filter { $0 == "/" || path == $0 || path.hasPrefix($0 + "/") }.max { $0.count < $1.count } ?? "/"
    }

    /// Whether two locations are on the same volume, judged by their writing alone. Two places
    /// of another file system count as one volume when they are on the same server.
    static func areOnSameVolume(_ first: URL, _ second: URL, mountPoints: [String]) -> Bool {
        guard first.isFileURL, second.isFileURL else {
            return (first.scheme, first.host, first.port) == (second.scheme, second.host, second.port)
        }
        return mountPoint(of: first.path, among: mountPoints) == mountPoint(of: second.path, among: mountPoints)
    }

    /// The question a drop asks before it starts, when the user wants to be asked
    /// (spec 05 › Drag & drop, Confirmation).
    static func question(_ kind: TransferKind, count: Int) -> String {
        "\(kind == .move ? "Move" : "Copy") \(count) item\(count == 1 ? "" : "s") to"
    }
}

/// Where the sources of a drag are, worked out once: the places themselves and the folders
/// they lie in. Whether a drop on a folder is pointless is then a matter of looking up that
/// folder and the folders above it, however many items are dragged.
struct DragSources {
    let isEmpty: Bool
    private let places: Set<String>
    private let folders: Set<String>

    init(_ sources: [URL]) {
        isEmpty = sources.isEmpty
        var places = Set<String>(minimumCapacity: sources.count)
        var folders = Set<String>()
        for source in sources {
            let key = source.locationKey
            places.insert(key)
            folders.insert(Self.parent(of: key) ?? source.deletingLastPathComponent().locationKey)
        }
        (self.places, self.folders) = (places, folders)
    }

    /// The key of the folder a location lies in, from its key alone; nil at the top.
    private static func parent(of key: String) -> String? {
        guard let scheme = key.range(of: "://"), let pathStart = key[scheme.upperBound...].firstIndex(of: "/"),
            let slash = key.lastIndex(of: "/"), key.index(after: slash) < key.endIndex
        else { return nil }
        // The root keeps its slash; everything else loses the last part of its path.
        return String(slash == pathStart ? key[...slash] : key[..<slash])
    }

    /// `PanelDrop.isPointless` for these sources.
    func isPointless(_ kind: TransferKind, into destination: URL) -> Bool {
        if isEmpty { return true }
        // Into one of the sources, or into a folder below one.
        var key: String? = destination.locationKey
        while let current = key {
            if places.contains(current) { return true }
            key = Self.parent(of: current)
        }
        return kind == .move && folders.count == 1 && folders.contains(destination.locationKey)
    }
}

/// What a drag carries and where its sources are, worked out once for the whole drag: the
/// mouse reports its position many times a second, and the items may be many thousands.
/// Main thread only.
final class DropSession {
    /// Identifies the drag (`NSDraggingInfo.draggingSequenceNumber`).
    let sequence: Int
    /// What is dragged; empty while the program's own drag is still putting its items together.
    private(set) var sources: [URL]
    /// The program's own drag, until its items are known.
    private var payload: PanelDrop.Payload?
    private var mounts: [String]?
    /// Where the sources are; nil while that is still being worked out, in the background,
    /// for a drag of very many items.
    private var places: DragSources?
    /// Whether dropping all sources on a destination is pointless, by kind and destination.
    private var verdicts: [String: Bool] = [:]

    /// From this many sources on, their places are worked out in the background.
    static let backgroundThreshold = 5_000

    init(sequence: Int, sources: [URL]) {
        self.sequence = sequence
        self.sources = sources
        locate()
    }

    /// The session of a drag that started in this program: the sources are taken when the
    /// drag has put them together.
    init(sequence: Int, payload: PanelDrop.Payload) {
        self.sequence = sequence
        sources = []
        guard !payload.isReady else {
            sources = payload.locations
            locate()
            return
        }
        self.payload = payload
        payload.whenReady { [weak self] locations in
            guard let self, self.payload != nil else { return }
            self.payload = nil
            sources = locations
            locate()
        }
    }

    private func locate() {
        let sources = sources
        if sources.count < Self.backgroundThreshold {
            places = DragSources(sources)
        } else {
            Background.compute(
                work: { DragSources(sources) },
                then: { [weak self] in
                    if let self, places == nil { places = $0 }
                })
        }
    }

    /// Everything is worked out here and now: the files were dropped before the background
    /// had got there, and a drop is not turned away for that.
    func finishNow() {
        if let payload {
            self.payload = nil
            sources = payload.locations
        }
        if places == nil { places = DragSources(sources) }
    }

    /// False until it is known where the sources are.
    var isReady: Bool { places != nil }

    /// Where the local volumes are mounted, asked of the system the first time it is needed.
    var mountPoints: [String] {
        if let mounts { return mounts }
        let mounts = PanelDrop.mountPoints()
        self.mounts = mounts
        return mounts
    }

    /// As long as it is not known where the sources are, every drop counts as pointless and
    /// nothing is taken: the mouse asks again in a moment.
    func isPointless(_ kind: TransferKind, into destination: URL) -> Bool {
        guard let places else { return true }
        let key = "\(kind)|\(destination.absoluteString)"
        if let verdict = verdicts[key] { return verdict }
        let verdict = places.isPointless(kind, into: destination)
        verdicts[key] = verdict
        return verdict
    }
}
