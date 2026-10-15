import AppKit

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
internal final class IconStore {
    /// A file as it was listed.
    private struct Key: Hashable {
        /// Its path.
        let path: String
        /// Its date when it was listed.
        let modified: Date

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.path == rhs.path && lhs.modified == rhs.modified
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(path)
            hasher.combine(modified)
        }
    }

    /// The store of the program, which every list shares.
    internal static let shared = IconStore()
    /// Posted on the main thread; `userInfo[pathsKey]` holds the paths (a `Set<String>`).
    internal static let didArrive = Notification.Name("AFMIconsDidArrive")
    /// The key of the paths in the `userInfo` of `didArrive`.
    nonisolated internal static let pathsKey = "paths"
    /// The icons of a few screens.
    internal static let limit = 4_000
    /// Most that wait for one folder; the ones asked for longest ago (rows long out of sight) are dropped.
    internal static let waitingLimit = 512
    /// Icons fetched in one trip.
    internal static let batchSize = 64

    /// Fetches the icon of the file at a path; called on background threads.
    ///
    /// The system's own by default, which may be asked from any thread.
    internal var source: @Sendable (String) -> NSImage = { NSWorkspace.shared.icon(forFile: $0) }
    private var icons = TwoGenerationCache<Key, NSImage>(limit: IconStore.limit)
    /// What is waiting, by folder, oldest first; the end of each line is served first.
    private var waiting: [String: [Key]] = [:]
    private var asked: Set<Key> = []
    /// The folders a trip is out for.
    private var busy: Set<String> = []

    /// An empty store whose icons come from the system.
    internal init() {
        // Every icon is fetched when it is first asked for.
    }

    /// The icon of the file at `path` as it was when it was changed last at `modified`, when it
    /// is there; otherwise nil, and it is on its way.
    internal func icon(forPath path: String, modified: Date) -> NSImage? {
        let key = Key(path: path, modified: modified)
        if let icon = icons[key] {
            return icon
        }
        guard asked.insert(key).inserted else {
            return nil
        }
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var line = waiting[folder] ?? []
        line.append(key)
        if line.count > Self.waitingLimit {
            for old in line.prefix(line.count - Self.waitingLimit) {
                asked.remove(old)
            }
            line.removeFirst(line.count - Self.waitingLimit)
        }
        waiting[folder] = line
        fetch(in: folder)
        return nil
    }

    /// Starts a trip for the icons that wait in `folder`, unless one is out for it already.
    private func fetch(in folder: String) {
        guard !busy.contains(folder), var line = waiting[folder], !line.isEmpty else {
            return
        }
        let count = min(Self.batchSize, line.count)
        let batch = Array(line.suffix(count).reversed())
        line.removeLast(count)
        waiting[folder] = line.isEmpty ? nil : line
        busy.insert(folder)
        Background.storage(
            "icons",
            at: URL(fileURLWithPath: folder, isDirectory: true),
            qos: .utility,
            work: { [source] in batch.map { source($0.path) } },
            then: { [weak self] fetched in self?.take(fetched, for: batch, in: folder) }
        )
    }

    /// A trip came back: the icons are kept, the lists hear of them, and the next trip starts.
    private func take(_ fetched: [NSImage], for batch: [Key], in folder: String) {
        busy.remove(folder)
        for (key, icon) in zip(batch, fetched) {
            asked.remove(key)
            icons[key] = icon
        }
        NotificationCenter.default.post(
            name: Self.didArrive,
            object: self,
            userInfo: [Self.pathsKey: Set(batch.map(\.path))]
        )
        fetch(in: folder)
    }

    deinit {
        // Nothing to release: a trip out holds no reference to the store.
    }
}
