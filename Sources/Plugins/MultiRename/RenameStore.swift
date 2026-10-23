import AFMKernel
import Foundation

/// What the Multi-Rename Tool remembers between sessions (spec 09 › Saved settings and
/// persistence): named settings, the histories of its fields and the runs that can be undone.
///
/// Main thread only, like the settings store behind it.
@MainActor
internal final class RenameStore {
    /// The fields that keep a history.
    internal enum History: String {
        /// The rename mask for the name.
        case nameMask = "history.nameMask"
        /// "Search for" of Search & Replace.
        case search = "history.search"
        /// "Replace with" of Search & Replace.
        case replacement = "history.replacement"
    }

    /// What the stores made on one settings object share.
    ///
    /// The lists are read from the settings once and then live here, so asking for them costs
    /// nothing (the undo history of a big run is megabytes of JSON). Changes are written at once
    /// for the small lists; the undo history of a big run is encoded on a background queue and
    /// handed to the settings from the main thread.
    @MainActor
    private final class Memory {
        weak var settings: any SettingsStore?
        var histories: [History: [String]] = [:]
        /// The saved settings, once `isSavedLoaded`.
        var saved: [String: RenameSettings] = [:]
        var isSavedLoaded = false
        /// The runs that can be undone, once `isUndoLoaded`.
        var undo: [[RenamedItem]] = []
        var isUndoLoaded = false
        /// Counts the changes of histories and saved settings, for whoever shows them.
        var revision = 0
        var undoWrite = 0

        init(_ settings: any SettingsStore) {
            self.settings = settings
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The corner of the settings the tool keeps its own values in.
    internal static let scope = "multirename"
    /// The most entries a history keeps.
    internal static let historyLimit = 20
    /// The runs kept for Undo are saved up to this many renamed files in all, newest first; a
    /// run that alone is longer is kept in memory for this session only and is not saved (a
    /// hundred thousand names are tens of megabytes of settings, which the program would read
    /// at every start).
    internal static let persistedItemLimit = 50_000
    /// The full keys of the preferences, as the configuration page stores them.
    internal static let undoLimitKey = scope + ".undoHistoryLength"
    /// The preference of the saved settings the tool opens with.
    internal static let startupSettingsKey = scope + ".loadSettings"
    /// The preference of the words kept in lower case in titles.
    internal static let lowercaseWordsKey = scope + ".lowercaseWords"

    private static var memories: [ObjectIdentifier: Memory] = [:]
    private static let memoriesLock = NSLock()
    /// Runs with more renamed files than this are saved in the background.
    private static let backgroundWriteThreshold = 2_000
    private static let writer = DispatchQueue(label: "multirename.store", qos: .utility)

    private let all: any SettingsStore
    private let own: any SettingsStore
    private let memory: Memory

    // MARK: Preferences

    /// How many runs can be undone; 0 turns Undo off (`MultiRenameUndoHistoryLen`).
    internal var undoLimit: Int {
        max(0, Int(all.text(Self.undoLimitKey, default: "20").trimmingCharacters(in: .whitespaces)) ?? 20)
    }

    /// The saved settings the tool opens with; empty for the last used ones (`MultiRenameLoadSettings`).
    internal var startupSettingsName: String { all.text(Self.startupSettingsKey, default: "") }

    /// How names are put in title case, with the words the preference keeps in lower case.
    internal var titleRule: TitleCaseRule {
        TitleCaseRule(setting: all.text(Self.lowercaseWordsKey, default: TitleCaseRule.defaultSetting))
    }

    // MARK: Saved settings

    /// Settings that cannot be read are left out; the others stay.
    internal var saved: [String: RenameSettings] {
        get {
            if memory.isSavedLoaded {
                return memory.saved
            }
            let loaded = (own.value([String: StoredElement<RenameSettings>].self, forKey: "saved") ?? [:])
                .compactMapValues(\.value)
            (memory.saved, memory.isSavedLoaded) = (loaded, true)
            return loaded
        }
        set {
            (memory.saved, memory.isSavedLoaded) = (newValue, true)
            memory.revision += 1
            own.set(newValue, forKey: "saved")
        }
    }

    /// The names of the saved settings, in name order.
    internal var savedNames: [String] { saved.keys.sorted { Sorter.compare($0, $1) == .orderedAscending } }

    /// Changes whenever a history or the saved settings change; a window that shows them
    /// need not rebuild them while it stays the same.
    internal var revision: Int { memory.revision }

    // MARK: Undo

    /// The runs that can be undone, the latest last.
    ///
    /// Kept in the settings, so Undo works after the tool, and the program, were closed.
    internal var undoHistory: [[RenamedItem]] {
        get {
            if memory.isUndoLoaded {
                return memory.undo
            }
            let loaded =
                own.largeData(forKey: "undo").flatMap { try? JSONDecoder().decode([[RenamedItem]].self, from: $0) }
                ?? []
            (memory.undo, memory.isUndoLoaded) = (loaded, true)
            return loaded
        }
        set {
            let runs = Array(newValue.suffix(undoLimit))
            (memory.undo, memory.isUndoLoaded) = (runs, true)
            persistUndo(runs)
        }
    }

    /// The number of runs that can be undone; cheap, unlike decoding them: it is kept beside them.
    internal var undoCount: Int {
        if memory.isUndoLoaded {
            return memory.undo.count
        }
        if let counted = own.value(Int.self, forKey: "undoCount") {
            return counted
        }
        // Runs saved without a count: there is something to undo if there is anything saved.
        return own.largeData(forKey: "undo") == nil ? 0 : 1
    }

    /// The newest run that can be undone; empty when there is none.
    internal var lastUndo: [RenamedItem] { undoHistory.last ?? [] }

    /// The store of the tool in `settings`; the stores made on one settings object share what they read.
    internal init(settings: any SettingsStore) {
        all = settings
        own = settings.scoped(to: Self.scope)
        memory = Self.memory(for: settings)
    }

    private static func memory(for settings: any SettingsStore) -> Memory {
        memoriesLock.lock()
        defer { memoriesLock.unlock() }
        memories = memories.filter { $0.value.settings != nil }
        if let known = memories[ObjectIdentifier(settings)], known.settings === settings {
            return known
        }
        let created = Memory(settings)
        memories[ObjectIdentifier(settings)] = created
        return created
    }

    // MARK: Histories

    /// What was typed into a field before, newest first.
    internal func history(_ history: History) -> [String] {
        if let known = memory.histories[history] {
            return known
        }
        let loaded = own.value([String].self, forKey: history.rawValue) ?? []
        memory.histories[history] = loaded
        return loaded
    }

    private func setHistory(_ entries: [String], _ history: History) {
        memory.histories[history] = entries
        memory.revision += 1
        own.set(entries, forKey: history.rawValue)
    }

    /// Puts a text at the top of a history.
    ///
    /// Leading and trailing spaces are kept: they matter in Search & Replace.
    internal func remember(_ text: String, in history: History) {
        guard !text.isEmpty else {
            return
        }
        var entries = self.history(history).filter { $0 != text }
        entries.insert(text, at: 0)
        setHistory(Array(entries.prefix(Self.historyLimit)), history)
    }

    /// Takes a text out of a history.
    internal func forget(_ text: String, in history: History) {
        setHistory(self.history(history).filter { $0 != text }, history)
    }

    /// Brings the undo history into memory, decoding it off the main thread; `completion` runs
    /// on the main thread.
    ///
    /// Asking for the history before this has finished decodes it where it is asked.
    internal func loadUndo(completion: @escaping @MainActor @Sendable () -> Void) {
        guard !memory.isUndoLoaded else {
            completion()
            return
        }
        let data = own.largeData(forKey: "undo")
        let shared = memory
        Self.writer.async {
            let decoded = data.flatMap { try? JSONDecoder().decode([[RenamedItem]].self, from: $0) } ?? []
            performOnMainLoop {
                if !shared.isUndoLoaded {
                    (shared.undo, shared.isUndoLoaded) = (decoded, true)
                }
                completion()
            }
        }
    }

    /// Adds a run as the newest, as far as Undo is on.
    internal func appendUndo(_ run: [RenamedItem]) {
        guard undoLimit > 0 else {
            return
        }
        var history = undoHistory
        history.append(run)
        undoHistory = history
    }

    /// After an Undo: the newest run is replaced by what of it is still to be undone.
    internal func replaceLastUndo(with remainder: [RenamedItem]) {
        var history = undoHistory
        if !history.isEmpty {
            history.removeLast()
        }
        if !remainder.isEmpty {
            history.append(remainder)
        }
        undoHistory = history
    }

    /// The runs that are saved: the newest ones, as many as fit the limit, without a gap (a
    /// run that does not fit ends the list, so the saved runs are always the last ones).
    private func persistedRuns(of runs: [[RenamedItem]]) -> [[RenamedItem]] {
        var kept: [[RenamedItem]] = []
        var total = 0
        for run in runs.reversed() {
            if total + run.count > Self.persistedItemLimit {
                break
            }
            kept.append(run)
            total += run.count
        }
        return kept.reversed()
    }

    private func persistUndo(_ runs: [[RenamedItem]]) {
        let kept = persistedRuns(of: runs)
        memory.undoWrite += 1
        own.set(kept.count, forKey: "undoCount")
        // The history may be megabytes: the settings keep it apart from the small values (the
        // store that does so writes it away from the main thread).
        guard kept.reduce(0, { $0 + $1.count }) > Self.backgroundWriteThreshold else {
            own.setLarge(try? JSONEncoder().encode(kept), forKey: "undo")
            return
        }
        let write = memory.undoWrite
        let (shared, scoped) = (memory, own)
        Self.writer.async {
            let data = try? JSONEncoder().encode(kept)
            DispatchQueue.main.async {
                // A newer change has its own write on the way (or was written at once).
                guard shared.undoWrite == write else {
                    return
                }
                scoped.setLarge(data, forKey: "undo")
            }
        }
    }

    /// Writes the undo history now, e.g. when the program ends before the background write
    /// has been handed in.
    internal func flush() {
        guard memory.isUndoLoaded else {
            return
        }
        memory.undoWrite += 1
        let kept = persistedRuns(of: memory.undo)
        own.set(kept.count, forKey: "undoCount")
        own.setLarge(try? JSONEncoder().encode(kept), forKey: "undo")
    }

    deinit {
        // Nothing to release: what the store read lives on in the memory of its settings.
    }
}
