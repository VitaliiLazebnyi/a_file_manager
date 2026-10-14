import AFMKernel
import Foundation

/// What the Multi-Rename Tool remembers between sessions (spec 09 › Saved settings and
/// persistence): named settings, the histories of its fields and the runs that can be undone.
/// Main thread only, like the settings store behind it.
final class RenameStore {
    /// The fields that keep a history.
    enum History: String {
        case nameMask = "history.nameMask"
        case search = "history.search"
        case replacement = "history.replacement"
    }

    static let scope = "multirename"
    static let historyLimit = 20
    /// The runs kept for Undo are saved up to this many renamed files in all, newest first; a
    /// run that alone is longer is kept in memory for this session only and is not saved (a
    /// hundred thousand names are tens of megabytes of settings, which the program would read
    /// at every start).
    static let persistedItemLimit = 50_000
    /// The full keys of the preferences, as the configuration page stores them.
    static let undoLimitKey = scope + ".undoHistoryLength"
    static let startupSettingsKey = scope + ".loadSettings"
    static let lowercaseWordsKey = scope + ".lowercaseWords"

    /// What the stores made on one settings object share. The lists are read from the settings
    /// once and then live here, so asking for them costs nothing (the undo history of a big
    /// run is megabytes of JSON). Changes are written at once for the small lists; the undo
    /// history of a big run is encoded on a background queue and handed to the settings from
    /// the main thread.
    private final class Memory {
        weak var settings: SettingsStore?
        var histories: [History: [String]] = [:]
        var saved: [String: RenameSettings]?
        var undo: [[RenamedItem]]?
        /// Counts the changes of histories and saved settings, for whoever shows them.
        var revision = 0
        var undoWrite = 0

        init(_ settings: SettingsStore) {
            self.settings = settings
        }
    }

    private static var memories: [ObjectIdentifier: Memory] = [:]
    private static let memoriesLock = NSLock()
    /// Runs with more renamed files than this are saved in the background.
    private static let backgroundWriteThreshold = 2_000
    private static let writer = DispatchQueue(label: "multirename.store", qos: .utility)

    private static func memory(for settings: SettingsStore) -> Memory {
        memoriesLock.lock()
        defer { memoriesLock.unlock() }
        memories = memories.filter { $0.value.settings != nil }
        if let known = memories[ObjectIdentifier(settings)], known.settings === settings { return known }
        let created = Memory(settings)
        memories[ObjectIdentifier(settings)] = created
        return created
    }

    private let all: SettingsStore
    private let own: SettingsStore
    private let memory: Memory

    init(settings: SettingsStore) {
        all = settings
        own = settings.scoped(to: RenameStore.scope)
        memory = RenameStore.memory(for: settings)
    }

    // MARK: Preferences

    /// How many runs can be undone; 0 turns Undo off (`MultiRenameUndoHistoryLen`).
    var undoLimit: Int {
        max(0, Int(all.text(RenameStore.undoLimitKey, default: "20").trimmingCharacters(in: .whitespaces)) ?? 20)
    }

    /// The saved settings the tool opens with; empty for the last used ones (`MultiRenameLoadSettings`).
    var startupSettingsName: String { all.text(RenameStore.startupSettingsKey, default: "") }

    var titleRule: TitleCaseRule {
        TitleCaseRule(setting: all.text(RenameStore.lowercaseWordsKey, default: TitleCaseRule.defaultSetting))
    }

    // MARK: Saved settings

    var saved: [String: RenameSettings] {
        get {
            if memory.saved == nil { memory.saved = own.value([String: RenameSettings].self, forKey: "saved") ?? [:] }
            return memory.saved ?? [:]
        }
        set {
            memory.saved = newValue
            memory.revision += 1
            own.set(newValue, forKey: "saved")
        }
    }

    var savedNames: [String] { saved.keys.sorted { Sorter.compare($0, $1) == .orderedAscending } }

    /// Changes whenever a history or the saved settings change; a window that shows them
    /// need not rebuild them while it stays the same.
    var revision: Int { memory.revision }

    // MARK: Histories

    func history(_ history: History) -> [String] {
        if let known = memory.histories[history] { return known }
        let loaded = own.value([String].self, forKey: history.rawValue) ?? []
        memory.histories[history] = loaded
        return loaded
    }

    private func setHistory(_ entries: [String], _ history: History) {
        memory.histories[history] = entries
        memory.revision += 1
        own.set(entries, forKey: history.rawValue)
    }

    /// Puts a text at the top of a history. Leading and trailing spaces are kept: they matter
    /// in Search & Replace.
    func remember(_ text: String, in history: History) {
        guard !text.isEmpty else { return }
        var entries = self.history(history).filter { $0 != text }
        entries.insert(text, at: 0)
        setHistory(Array(entries.prefix(RenameStore.historyLimit)), history)
    }

    func forget(_ text: String, in history: History) {
        setHistory(self.history(history).filter { $0 != text }, history)
    }

    // MARK: Undo

    /// The runs that can be undone, the latest last. Kept in the settings, so Undo works
    /// after the tool, and the program, were closed.
    var undoHistory: [[RenamedItem]] {
        get {
            if memory.undo == nil {
                memory.undo =
                    own.largeData(forKey: "undo").flatMap { try? JSONDecoder().decode([[RenamedItem]].self, from: $0) }
                    ?? []
            }
            return memory.undo ?? []
        }
        set {
            memory.undo = Array(newValue.suffix(undoLimit))
            persistUndo()
        }
    }

    /// The number of runs that can be undone; cheap, unlike decoding them: it is kept beside them.
    var undoCount: Int {
        if let loaded = memory.undo { return loaded.count }
        if let counted = own.value(Int.self, forKey: "undoCount") { return counted }
        // Runs saved without a count: there is something to undo if there is anything saved.
        return own.largeData(forKey: "undo") == nil ? 0 : 1
    }

    var lastUndo: [RenamedItem]? { undoHistory.last }

    /// Brings the undo history into memory, decoding it off the main thread; `completion` runs
    /// on the main thread. Asking for the history before this has finished decodes it where it is asked.
    func loadUndo(completion: @escaping () -> Void = {}) {
        guard memory.undo == nil else { return completion() }
        let data = own.largeData(forKey: "undo")
        let memory = self.memory
        RenameStore.writer.async {
            let decoded = data.flatMap { try? JSONDecoder().decode([[RenamedItem]].self, from: $0) } ?? []
            performOnMainLoop {
                if memory.undo == nil { memory.undo = decoded }
                completion()
            }
        }
    }

    /// Adds a run as the newest, as far as Undo is on.
    func appendUndo(_ run: [RenamedItem]) {
        guard undoLimit > 0 else { return }
        var history = undoHistory
        history.append(run)
        undoHistory = history
    }

    /// After an Undo: the newest run is replaced by what of it is still to be undone.
    func replaceLastUndo(with remainder: [RenamedItem]) {
        var history = undoHistory
        if !history.isEmpty { history.removeLast() }
        if !remainder.isEmpty { history.append(remainder) }
        undoHistory = history
    }

    /// The runs that are saved: the newest ones, as many as fit the limit, without a gap (a
    /// run that does not fit ends the list, so the saved runs are always the last ones).
    private func persistedRuns() -> [[RenamedItem]] {
        var kept: [[RenamedItem]] = []
        var total = 0
        for run in (memory.undo ?? []).reversed() {
            if total + run.count > RenameStore.persistedItemLimit { break }
            kept.append(run)
            total += run.count
        }
        return kept.reversed()
    }

    private func persistUndo() {
        let kept = persistedRuns()
        memory.undoWrite += 1
        own.set(kept.count, forKey: "undoCount")
        // The history may be megabytes: the settings keep it apart from the small values (the
        // store that does so writes it away from the main thread).
        guard kept.reduce(0, { $0 + $1.count }) > RenameStore.backgroundWriteThreshold else {
            return own.setLarge(try? JSONEncoder().encode(kept), forKey: "undo")
        }
        let write = memory.undoWrite
        let (memory, own) = (self.memory, self.own)
        RenameStore.writer.async {
            let data = try? JSONEncoder().encode(kept)
            DispatchQueue.main.async {
                // A newer change has its own write on the way (or was written at once).
                guard memory.undoWrite == write else { return }
                own.setLarge(data, forKey: "undo")
            }
        }
    }

    /// Writes the undo history now, e.g. when the program ends before the background write
    /// has been handed in.
    func flush() {
        guard memory.undo != nil else { return }
        memory.undoWrite += 1
        let kept = persistedRuns()
        own.set(kept.count, forKey: "undoCount")
        own.setLarge(try? JSONEncoder().encode(kept), forKey: "undo")
    }
}

/// Reads a list of names from a text file (spec 09 › Name-list menu): UTF-8 with or without
/// a byte-order mark, UTF-16, or the Western code page; Windows or Unix line ends.
enum RenameNameList {
    static func text(from data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16) ?? ""
        }
        // UTF-16 without a mark shows in the zero bytes between Latin letters.
        if data.count >= 2, data.count % 2 == 0, data[data.startIndex + 1] == 0,
            let text = String(data: data, encoding: .utf16LittleEndian)
        {
            return text
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
    }

    /// One name per line; empty lines at the end do not count.
    static func names(in text: String) -> [String] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }
}
