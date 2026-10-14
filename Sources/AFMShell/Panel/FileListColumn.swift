import AFMContracts
import AFMKernel
import AppKit
import UniformTypeIdentifiers

/// The columns of the Full view and how a row is drawn in each (spec 03 › Rows in Full view).
@MainActor
enum FileListColumn: String, CaseIterable {
    case name, ext, size, date, attr

    var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }

    var title: String {
        switch self {
        case .name: return "Name"
        case .ext: return "Ext"
        case .size: return "Size"
        case .date: return "Date"
        case .attr: return "Attr"
        }
    }

    private var width: CGFloat {
        switch self {
        case .name: return 260
        case .ext: return 60
        case .size: return 100
        case .date: return 125
        case .attr: return 85
        }
    }

    /// The sort key a click on the header chooses; Attr does not sort.
    var sortKey: SortKey? {
        switch self {
        case .name: return .name
        case .ext: return .ext
        case .size: return .size
        case .date: return .date
        case .attr: return nil
        }
    }

    /// The command a click on the header runs.
    var sortCommand: CommandID? {
        switch self {
        case .name: return .sortByName
        case .ext: return .sortByExtension
        case .size: return .sortBySize
        case .date: return .sortByTime
        case .attr: return nil
        }
    }

    func makeTableColumn() -> NSTableColumn {
        let column = NSTableColumn(identifier: identifier)
        column.title = title
        column.width = width
        column.minWidth = 40
        column.resizingMask = self == .name ? [.autoresizingMask, .userResizingMask] : .userResizingMask
        if self == .size { column.headerCell.alignment = .right }
        return column
    }

    /// The text of a row; `item` is nil for the `[..]` row. Names are shown with whatever
    /// could mislead made visible (`DisplayText`).
    func text(for item: FileItem?) -> String {
        guard let item else { return self == .name ? "[..]" : self == .size ? "<DIR>" : "" }
        switch self {
        case .name:
            return DisplayText.clean(item.isFolder ? "[\(item.name)]" : item.baseName)

        case .ext:
            return DisplayText.clean(item.ext)

        case .size:
            if !item.isDirectory { return Format.bytes(item.size) }
            if let size = item.computedSize { return Format.bytes(size) }
            return item.isPackage ? "<PKG>" : item.isSymlink ? "<LNK>" : "<DIR>"

        case .date:
            return Format.date(item.modified)

        case .attr:
            return Format.permissions(item.permissions)
        }
    }

    /// `color` is the colour of the row's text (`PanelViewController.nameColor`); `ownIcons`
    /// says whether each file may be asked for its own icon (see `icon(for:own:)`). Only what
    /// differs from what the cell shows is set, so filling a cell that is up to date costs
    /// a few comparisons and no drawing.
    func fill(_ cell: NSTableCellView, with item: FileItem?, color: NSColor, ownIcons: Bool) {
        if let field = cell.textField {
            let text = text(for: item)
            if field.stringValue != text { field.stringValue = text }
            if field.textColor != color { field.textColor = color }
        }
        guard self == .name, let imageView = cell.imageView else { return }
        let icon = item.map { Self.icon(for: $0, own: ownIcons) } ?? Self.parentIcon
        if imageView.image !== icon { imageView.image = icon }
        let alpha: CGFloat = item?.isHidden == true ? 0.5 : 1
        if imageView.alphaValue != alpha { imageView.alphaValue = alpha }
    }

    /// The icons of file types, by extension; main thread only. Extensions are whatever the
    /// names in a folder end in, so the store is bounded like the others.
    private static var typeIcons = TwoGenerationCache<String, NSImage>(limit: 2_000)

    /// The icon of the `[..]` row.
    static let parentIcon = NSImage(
        systemSymbolName: "arrow.turn.left.up", accessibilityDescription: "Parent directory")

    /// On a local disk a file shows its own icon. Asking the system for it reads the file's
    /// surroundings, which takes 30 µs for a plain file on a good day and for ever on a disk
    /// that does not answer, so it is never asked on the main thread: until the icon has been
    /// fetched in the background (`IconStore`) the file shows the icon of its type, which is
    /// looked up once per extension. A file that is not on a volume of this machine (a share,
    /// whatever the folder it is listed in says) is never asked at all: there every question
    /// is a trip to the server.
    static func icon(for item: FileItem, own: Bool) -> NSImage {
        if own, item.url.isFileURL {
            let path = item.url.path
            if Mounts.isLocal(path: path), let icon = IconStore.shared.icon(forPath: path, modified: item.modified) {
                return icon
            }
        }
        let key = item.isFolder ? "/folder" : item.url.pathExtension.lowercased()
        if let cached = typeIcons[key] { return cached }
        let icon =
            item.isFolder
            ? NSWorkspace.shared.icon(for: .folder)
            : NSWorkspace.shared.icon(for: UTType(filenameExtension: key) ?? .data)
        typeIcons[key] = icon
        return icon
    }

    /// The cells of all plugin columns are alike, so they share one kind of cell.
    static let extraCellIdentifier = NSUserInterfaceItemIdentifier("extra")

    static func makeExtraCell() -> NSTableCellView {
        let cell = Self.ext.makeCell()
        cell.identifier = extraCellIdentifier
        return cell
    }

    /// A cell is a label, and for the name an icon in front of it, placed by their frames: the
    /// table makes and moves many cells while it scrolls, and layout constraints for each of
    /// them were most of what that cost.
    func makeCell() -> NSTableCellView {
        let size = NSSize(width: 120, height: 20)
        let cell = NSTableCellView(frame: NSRect(origin: .zero, size: size))
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = self == .name ? .byTruncatingMiddle : .byTruncatingTail
        label.font =
            self == .name || self == .ext
            ? .systemFont(ofSize: 12)
            : .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.alignment = self == .size ? .right : .left
        var leading: CGFloat = 0
        if self == .name {
            let icon = NSImageView(frame: NSRect(x: 2, y: (size.height - 16) / 2, width: 16, height: 16))
            icon.imageScaling = .scaleProportionallyUpOrDown
            // Stays at the left edge, in the middle of the row's height.
            icon.autoresizingMask = [.maxXMargin, .minYMargin, .maxYMargin]
            cell.addSubview(icon)
            cell.imageView = icon
            leading = 2 + 16 + 5
        }
        let height = min(size.height, max(14, ceil(label.intrinsicContentSize.height)))
        label.frame = NSRect(
            x: leading, y: ((size.height - height) / 2).rounded(), width: size.width - leading, height: height)
        // As wide as the cell from where it starts, in the middle of the row's height.
        label.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        cell.addSubview(label)
        cell.textField = label
        return cell
    }
}

/// A store that forgets what was not used for a while without ever starting over: entries
/// live in two generations, the newer one filling up while the older is still looked at; when
/// the newer is full, the older is dropped and the newer takes its place. What is in use is
/// carried over as it is asked for, so it holds at most `limit` entries and a full store does
/// not mean that everything on screen is missing again.
struct TwoGenerationCache<Key: Hashable, Value> {
    let limit: Int
    private var recent: [Key: Value] = [:]
    private var older: [Key: Value] = [:]

    init(limit: Int) {
        self.limit = max(2, limit)
    }

    var count: Int { recent.count + older.count }

    subscript(key: Key) -> Value? {
        mutating get {
            if let value = recent[key] { return value }
            guard let value = older.removeValue(forKey: key) else { return nil }
            insert(value, for: key)
            return value
        }
        set {
            if let newValue { insert(newValue, for: key) } else { (recent[key], older[key]) = (nil, nil) }
        }
    }

    private mutating func insert(_ value: Value, for key: Key) {
        if recent.count >= limit / 2, recent[key] == nil {
            older = recent
            recent = [:]
        }
        recent[key] = value
        older[key] = nil
    }
}

/// The own icons of local files, fetched in the background.
///
/// A list asks for the icon of a file when it draws it. An icon that is not there yet is put
/// in line, the caller shows the icon of the file's type meanwhile, and `didArrive` is posted
/// when icons have come, for the lists to draw those rows again. Icons are fetched in the lane
/// of the folder the file is in (`Background`), a handful per trip, the files asked for last
/// first because those are the ones on screen; while a trip for a folder is out no second one
/// starts for it, so a folder that does not answer leaves its files with the icons of their
/// types and holds up nothing else. An icon belongs to the file as it was listed (its date),
/// so a changed file is asked again.
///
/// **Threading.** Main thread only; `source` is called on background threads.
@MainActor
final class IconStore {
    static let shared = IconStore()
    /// Posted on the main thread; `userInfo[pathsKey]` holds the paths (a `Set<String>`).
    static let didArrive = Notification.Name("AFMIconsDidArrive")
    nonisolated static let pathsKey = "paths"

    private struct Key: Hashable {
        let path: String
        let modified: Date
    }

    /// Fetches the icon of the file at a path; called on background threads. The system's own
    /// by default, which may be asked from any thread.
    var source: @Sendable (String) -> NSImage = { NSWorkspace.shared.icon(forFile: $0) }
    private var icons = TwoGenerationCache<Key, NSImage>(limit: IconStore.limit)
    /// What is waiting, by folder, oldest first; the end of each line is served first.
    private var waiting: [String: [Key]] = [:]
    private var asked: Set<Key> = []
    /// The folders a trip is out for.
    private var busy: Set<String> = []

    /// The icons of a few screens.
    static let limit = 4_000
    /// Most that wait for one folder; the ones asked for longest ago (rows long out of sight) are dropped.
    static let waitingLimit = 512
    /// Icons fetched in one trip.
    static let batchSize = 64

    /// The icon, when it is there; otherwise nil, and it is on its way.
    func icon(forPath path: String, modified: Date) -> NSImage? {
        MainThread.assert("The icons")
        let key = Key(path: path, modified: modified)
        if let icon = icons[key] { return icon }
        guard asked.insert(key).inserted else { return nil }
        let folder = (path as NSString).deletingLastPathComponent
        var line = waiting[folder] ?? []
        line.append(key)
        if line.count > Self.waitingLimit {
            line.prefix(line.count - Self.waitingLimit).forEach { asked.remove($0) }
            line.removeFirst(line.count - Self.waitingLimit)
        }
        waiting[folder] = line
        fetch(in: folder)
        return nil
    }

    /// True while icons are being fetched or wait for it.
    var isBusy: Bool { !busy.isEmpty || !waiting.isEmpty }

    /// Forgets every icon, for checks.
    func removeAll() {
        icons = TwoGenerationCache(limit: Self.limit)
    }

    private func fetch(in folder: String) {
        guard !busy.contains(folder), var line = waiting[folder], !line.isEmpty else { return }
        let count = min(Self.batchSize, line.count)
        let batch = Array(line.suffix(count).reversed())
        line.removeLast(count)
        waiting[folder] = line.isEmpty ? nil : line
        busy.insert(folder)
        let source = source
        Background.storage(
            "icons", at: URL(fileURLWithPath: folder, isDirectory: true), qos: .utility,
            // An image may go from thread to thread once it is made.
            work: { Handover(batch.map { source($0.path) }) },
            then: { [weak self] fetched in
                guard let self else { return }
                let fetched = fetched.value
                busy.remove(folder)
                for (key, icon) in zip(batch, fetched) {
                    asked.remove(key)
                    icons[key] = icon
                }
                NotificationCenter.default.post(
                    name: Self.didArrive, object: self, userInfo: [Self.pathsKey: Set(batch.map(\.path))])
                fetch(in: folder)
            })
    }
}
