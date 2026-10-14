public import AFMKernel
public import Foundation

/// The directories one panel visited, oldest first (spec 03 › Directory history list). The
/// panel's own back/forward list forgets what lay ahead; this one keeps every place once.
public struct DirectoryHistory: Codable, Equatable {
    public struct Visit: Codable, Equatable {
        /// The location as a URL string, so it can be on any file system.
        public var location: String
        /// False for a folder that was only passed through: thinning hides it from the list.
        public var isVisible: Bool
        /// The location key of `location`, worked out once, so that looking a visit up does not
        /// parse a URL for each of the 200 that are kept. Not stored.
        public private(set) var key: String

        private enum CodingKeys: String, CodingKey { case location, isVisible }

        public init(location: String, isVisible: Bool) {
            self.location = location
            self.isVisible = isVisible
            key = URL(string: location)?.locationKey ?? ""
        }
    }

    /// The location as it is stored: a password in a URL is left out, because histories land
    /// in the settings, which are exported and shared.
    static func stored(_ directory: URL) -> String {
        let text = directory.absoluteString
        guard text.contains("@"), var components = URLComponents(string: text), components.password != nil else {
            return text
        }
        components.password = nil
        return components.string ?? text
    }

    /// What is kept per panel (`HistoryLenStored`).
    public static let storedLimit = 200

    public private(set) var visits: [Visit] = []

    public init() {}

    /// The directory the panel is in, as far as the history knows.
    public var current: URL? { visits.last.flatMap { URL(string: $0.location) } }

    /// The panel shows `directory` now. `stayedInPrevious` says whether the directory it left
    /// was more than passed through; that one then stays visible under thinning. A directory
    /// that was visited before moves to the end. Returns false when nothing changed.
    @discardableResult
    public mutating func record(_ directory: URL, stayedInPrevious: Bool) -> Bool {
        let key = directory.locationKey
        if let last = visits.last, last.key == key { return false }
        if stayedInPrevious, !visits.isEmpty { visits[visits.count - 1].isVisible = true }
        let earlier = visits.firstIndex { $0.key == key }
        let wasVisible = earlier.map { visits.remove(at: $0).isVisible } ?? false
        visits.append(Visit(location: Self.stored(directory), isVisible: wasVisible))
        if visits.count > Self.storedLimit {
            visits.removeFirst(visits.count - Self.storedLimit)
        }
        return true
    }

    /// Shift+Del in the list: forgets a directory.
    public mutating func remove(_ directory: URL) {
        let key = directory.locationKey
        visits.removeAll { $0.key == key }
    }

    /// The list as it is shown: the last visited first. With `thinning`, folders that were
    /// only passed through are left out; the current directory is always there.
    public func shown(thinning: Bool, limit: Int? = nil) -> [URL] {
        let last = visits.count - 1
        let urls = visits.enumerated().reversed().compactMap { index, visit in
            !thinning || visit.isVisible || index == last ? URL(string: visit.location) : nil
        }
        return limit.map { Array(urls.prefix(max($0, 1))) } ?? urls
    }
}

// Stored histories are read leniently (see `StoredSettings`).
extension DirectoryHistory.Visit {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            location: try container.decode(String.self, forKey: .location),
            isVisible: try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? false)
    }
}

extension DirectoryHistory {
    private enum Keys: String, CodingKey { case visits }

    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: Keys.self)
        visits = Array(
            (try container.decodeIfPresent(LenientElements<Visit>.self, forKey: .visits)?.elements ?? []).suffix(
                Self.storedLimit))
    }
}

extension FrequentFolders {
    private enum Keys: String, CodingKey { case counts }

    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: Keys.self)
        let stored = try container.decodeIfPresent([String: Int].self, forKey: .counts) ?? [:]
        // No negative count, and no more than are kept: the most visited stay.
        let kept =
            stored.count > Self.storedLimit
            ? Array(stored.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.prefix(Self.storedLimit))
            : Array(stored)
        counts = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, max($0.value, 0)) })
    }
}

/// How often each directory was visited, in either panel (spec 03 › Directory history list,
/// "frequently used folders").
public struct FrequentFolders: Codable, Equatable {
    /// What is kept (`FrequentlyUsedLenStored`).
    public static let storedLimit = 200

    public private(set) var counts: [String: Int] = [:]

    public init() {}

    public mutating func record(_ directory: URL) {
        let own = DirectoryHistory.stored(directory)
        // A stored count can be anything (settings are imported): it stops at the top.
        let before = counts[own] ?? 0
        counts[own] = before == Int.max ? before : before + 1
        guard counts.count > Self.storedLimit else { return }
        // The least visited folder makes room; the one just counted stays.
        if let rarest = counts.filter({ $0.key != own }).min(by: { ($0.value, $0.key) < ($1.value, $1.key) }) {
            counts[rarest.key] = nil
        }
    }

    public mutating func remove(_ directory: URL) {
        let key = directory.locationKey
        counts = counts.filter { URL(string: $0.key)?.locationKey != key }
    }

    /// The most visited folders, the most frequent first.
    public func top(_ limit: Int? = nil) -> [(directory: URL, visits: Int)] {
        let ranked = counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.compactMap { entry in
            URL(string: entry.key).map { (directory: $0, visits: entry.value) }
        }
        return limit.map { Array(ranked.prefix(max($0, 0))) } ?? ranked
    }
}

/// The history pop-up as a list of rows: the panel's history, then the frequently used
/// folders (spec 03 › Directory history list).
public struct HistoryMenu {
    public enum Row: Equatable {
        case visit(URL)
        case separator
        case frequent(URL)

        public var directory: URL? {
            switch self {
            case .visit(let url), .frequent(let url): return url
            case .separator: return nil
            }
        }
    }

    public let rows: [Row]
    public let titles: [String]
    /// The row of the directory the panel shows.
    public let selected: Int

    public init(history: [URL], frequent: [(directory: URL, visits: Int)], current: URL, displayPath: (URL) -> String) {
        var rows = history.map(Row.visit)
        var titles = history.map { ($0.isSameLocation(as: current) ? "➤ " : "    ") + displayPath($0) }
        if !frequent.isEmpty {
            if !rows.isEmpty {
                rows.append(.separator)
                titles.append("──────  Frequently used  ──────")
            }
            rows += frequent.map { .frequent($0.directory) }
            titles += frequent.map { "    " + displayPath($0.directory) + "   (\($0.visits))" }
        }
        self.rows = rows
        self.titles = titles
        selected = history.firstIndex { $0.isSameLocation(as: current) } ?? 0
    }
}

/// Follows the panels and keeps their histories (spec 13 › Operation › History). Main thread
/// only; it is fed from `PanelEvents` and never touches a file system.
public final class DirectoryHistoryTracker {
    public enum Side: String, CaseIterable {
        case left, right
    }

    /// A stay at least this long makes a folder more than "passed through" (`HistoryThinningDelta`).
    public static let thinningDelta: TimeInterval = 5

    private let settings: any SettingsStore
    private let now: () -> Date
    /// Whether changes are written to the settings as they happen ("Save history on exit").
    public var savesChanges: () -> Bool = { true }
    private var histories: [Side: DirectoryHistory] = [:]
    private var entered: [Side: Date] = [:]
    public private(set) var frequent: FrequentFolders
    /// What has changed since it was written; a burst of navigation is written once.
    private var changedSides = Set<Side>()
    private var frequentChanged = false
    private var writeIsScheduled = false
    /// How long a change waits for further ones before it is written.
    public static let writeDelay: TimeInterval = 1

    /// `settings` is the plugin's own corner of the settings store. `problem` is told when
    /// stored data could not be read in full; the original is kept aside (`StoredSettings`).
    public init(
        settings: any SettingsStore, now: @escaping () -> Date = Date.init, problem: (String) -> Void = { _ in }
    ) {
        self.settings = settings
        self.now = now
        for side in Side.allCases {
            histories[side] = StoredSettings.load(
                DirectoryHistory.self, key: Self.key(side), in: settings, problem: problem)
        }
        frequent =
            StoredSettings.load(
                FrequentFolders.self, key: Self.frequentKey, in: settings, problem: problem)
            ?? FrequentFolders()
    }

    private static func key(_ side: Side) -> String { "history." + side.rawValue }
    private static let frequentKey = "history.frequent"

    public func history(of side: Side) -> DirectoryHistory {
        histories[side] ?? DirectoryHistory()
    }

    /// The panel on `side` shows `directory`. Called for every location event, also when the
    /// directory is still the same.
    public func visited(_ directory: URL, on side: Side) {
        var history = history(of: side)
        let time = now()
        let stayed = entered[side].map { time.timeIntervalSince($0) >= Self.thinningDelta } ?? false
        guard history.record(directory.standardized, stayedInPrevious: stayed) else { return }
        entered[side] = time
        histories[side] = history
        frequent.record(directory.standardized)
        changed(side, frequent: true)
    }

    public func remove(_ directory: URL, from side: Side) {
        var history = history(of: side)
        history.remove(directory)
        histories[side] = history
        changed(side, frequent: false)
    }

    public func removeFrequent(_ directory: URL) {
        frequent.remove(directory)
        changed(nil, frequent: true)
    }

    /// Notes what changed and has it written shortly, off the path of the navigation.
    private func changed(_ side: Side?, frequent isFrequent: Bool) {
        guard savesChanges() else { return }
        if let side { changedSides.insert(side) }
        if isFrequent { frequentChanged = true }
        guard !writeIsScheduled else { return }
        writeIsScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.writeDelay) { [weak self] in
            self?.writeChanges()
        }
    }

    /// Writes what is waiting to be written now.
    public func flush() { writeChanges() }

    private func writeChanges() {
        writeIsScheduled = false
        guard savesChanges() else { return }
        for side in changedSides { settings.set(history(of: side), forKey: Self.key(side)) }
        if frequentChanged { settings.set(frequent, forKey: Self.frequentKey) }
        changedSides = []
        frequentChanged = false
    }

    /// "Save now".
    public func save() {
        for side in Side.allCases { settings.set(history(of: side), forKey: Self.key(side)) }
        settings.set(frequent, forKey: Self.frequentKey)
        changedSides = []
        frequentChanged = false
    }

    /// "Delete now": forgets both histories and the frequently used folders, in memory and in
    /// the settings.
    public func clear() {
        histories = [:]
        entered = [:]
        changedSides = []
        frequentChanged = false
        frequent = FrequentFolders()
        for side in Side.allCases { settings.set(nil as Data?, forKey: Self.key(side)) }
        settings.set(nil as Data?, forKey: Self.frequentKey)
    }
}
