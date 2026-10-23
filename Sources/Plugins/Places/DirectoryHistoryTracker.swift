public import AFMKernel
public import Foundation

/// Follows the panels and keeps their histories (spec 13 › Operation › History).
///
/// Main thread only; it is fed from `PanelEvents` and never touches a file system.
@preconcurrency
@MainActor
public final class DirectoryHistoryTracker {
    /// The panel a history belongs to; the raw value names its settings key (`history.left`, `history.right`).
    public enum Side: String, CaseIterable {
        /// The left panel.
        case left = "left"
        /// The right panel.
        case right = "right"
    }

    /// A stay at least this long makes a folder more than "passed through" (`HistoryThinningDelta`).
    public static let thinningDelta: TimeInterval = 5
    /// How long a change waits for further ones before it is written.
    public static let writeDelay: TimeInterval = 1
    /// The settings key of the frequently used folders.
    private static let frequentKey = "history.frequent"

    /// The plugin's own corner of the settings store.
    private let settings: any SettingsStore
    /// The clock that times the stays (a test passes its own).
    private let now: () -> Date
    /// Whether changes are written to the settings as they happen ("Save history on exit").
    public var savesChanges: () -> Bool = { true }
    /// The history of each panel; a side without one has an empty history.
    private var histories: [Side: DirectoryHistory] = [:]
    /// When each panel entered the directory it shows.
    private var entered: [Side: Date] = [:]
    /// How often each directory was visited, in either panel.
    public private(set) var frequent: FrequentFolders
    /// What has changed since it was written; a burst of navigation is written once.
    private var changedSides = Set<Side>()
    /// Whether `frequent` changed since it was written.
    private var frequentChanged = false
    /// Whether a write is waiting on the main queue.
    private var writeIsScheduled = false

    /// Loads the stored histories and frequently used folders.
    ///
    /// `settings` is the plugin's own corner of the settings store. `problem` is told when
    /// stored data could not be read in full; the original is kept aside (`StoredSettings`).
    public init(
        settings: any SettingsStore,
        now: @escaping () -> Date = Date.init,
        problem: (String) -> Void = { _ in
            // Nobody to tell unless the caller asks.
        }
    ) {
        self.settings = settings
        self.now = now
        for side in Side.allCases {
            histories[side] = StoredSettings.load(
                DirectoryHistory.self,
                key: Self.key(side),
                in: settings,
                problem: problem
            )
        }
        frequent =
            StoredSettings.load(
                FrequentFolders.self,
                key: Self.frequentKey,
                in: settings,
                problem: problem
            )
            ?? FrequentFolders()
    }

    /// The settings key of the history of `side`.
    private static func key(_ side: Side) -> String { "history." + side.rawValue }

    /// The history of the panel on `side`; empty when it has none yet.
    public func history(of side: Side) -> DirectoryHistory {
        histories[side] ?? DirectoryHistory()
    }

    /// The panel on `side` shows `directory`.
    ///
    /// Called for every location event, also when the directory is still the same.
    public func visited(_ directory: URL, on side: Side) {
        var history = history(of: side)
        let time = now()
        let stayed = entered[side].map { time.timeIntervalSince($0) >= Self.thinningDelta } ?? false
        guard history.record(directory.standardized, stayedInPrevious: stayed) else {
            return
        }
        entered[side] = time
        histories[side] = history
        frequent.record(directory.standardized)
        changed(side, frequent: true)
    }

    /// Shift+Del in the history list of `side`: forgets `directory` there.
    public func remove(_ directory: URL, from side: Side) {
        var history = history(of: side)
        history.remove(directory)
        histories[side] = history
        changed(side, frequent: false)
    }

    /// Shift+Del in the frequently used folders: forgets the count of `directory`.
    public func removeFrequent(_ directory: URL) {
        frequent.remove(directory)
        changed(nil, frequent: true)
    }

    /// Notes what changed and has it written shortly, off the path of the navigation.
    private func changed(_ side: Side?, frequent isFrequent: Bool) {
        guard savesChanges() else {
            return
        }
        if let side {
            changedSides.insert(side)
        }
        if isFrequent {
            frequentChanged = true
        }
        guard !writeIsScheduled else {
            return
        }
        writeIsScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.writeDelay) { [weak self] in
            // The main queue runs its blocks on the main thread.
            MainActor.assumeIsolated { self?.writeChanges() }
        }
    }

    /// Writes what is waiting to be written now.
    public func flush() { writeChanges() }

    /// Writes the changed histories and counts, unless saving is off.
    private func writeChanges() {
        writeIsScheduled = false
        guard savesChanges() else {
            return
        }
        for side in changedSides {
            settings.set(history(of: side), forKey: Self.key(side))
        }
        if frequentChanged {
            settings.set(frequent, forKey: Self.frequentKey)
        }
        changedSides = []
        frequentChanged = false
    }

    /// "Save now".
    public func save() {
        for side in Side.allCases {
            settings.set(history(of: side), forKey: Self.key(side))
        }
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
        for side in Side.allCases {
            settings.set(nil as Data?, forKey: Self.key(side))
        }
        settings.set(nil as Data?, forKey: Self.frequentKey)
    }

    deinit {
        // Nothing to release.
    }
}
