import AFMKernel
import Foundation

/// A predefined selection type: a mask with further conditions, saved under a name and used
/// in Select group as `>name` (spec 03 › Select and unselect group, 18 › File masks and
/// selection types). Total Commander saves a whole search here; this holds what a file list
/// knows of its entries: kind, size, date of last change, hidden and link.
struct SelectionType: Codable, Equatable {
    enum Kind: Int, Codable {
        case any, files, folders
    }

    /// A condition on a yes/no property.
    enum Tri: Int, Codable {
        case any, yes, no

        func accepts(_ value: Bool) -> Bool { self == .any || (self == .yes) == value }
    }

    var name: String
    var mask = "*.*"
    var kind = Kind.any
    /// Size limits in bytes; they are asked of files only, and a folder never passes them.
    var minSize: Int64?
    var maxSize: Int64?
    var modifiedFrom: Date?
    var modifiedTo: Date?
    /// Changed within the last so many days, counted back from the moment of selecting.
    var notOlderThanDays: Int?
    var hidden = Tri.any
    var links = Tri.any

    /// The conditions beyond the mask.
    func accepts(_ item: FileItem, now: Date = Date()) -> Bool {
        switch kind {
        case .any: break
        case .files: if item.isFolder { return false }
        case .folders: if !item.isFolder { return false }
        }
        if minSize != nil || maxSize != nil {
            guard !item.isFolder else { return false }
            if let minSize, item.size < minSize { return false }
            if let maxSize, item.size > maxSize { return false }
        }
        if let modifiedFrom, item.modified < modifiedFrom { return false }
        if let modifiedTo, item.modified > modifiedTo { return false }
        if let notOlderThanDays, item.modified < now.addingTimeInterval(-Double(notOlderThanDays) * 86_400) {
            return false
        }
        return hidden.accepts(item.isHidden) && links.accepts(item.isSymlink)
    }

    // MARK: Text forms of the dialog

    /// `1500`, `10k`, `1.5 M`, `2g`; nil for anything else.
    static func size(from text: String) -> Int64? {
        var text = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return nil }
        var factor = 1.0
        if let unit = text.last, let power = ["b": 0, "k": 1, "m": 2, "g": 3, "t": 4][unit] {
            factor = pow(1_024, Double(power))
            text = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard let number = Double(text.replacingOccurrences(of: ",", with: "")), number >= 0 else { return nil }
        // `1e30` or `inf` is a size larger than any file, not a crash.
        let bytes = number * factor
        return bytes.isFinite && bytes < 9.2e18 ? Int64(bytes) : Int64.max
    }

    static func text(ofSize size: Int64?) -> String {
        guard let size else { return "" }
        for (unit, power) in [("G", 3), ("M", 2), ("k", 1)] {
            let factor = Int64(pow(1_024, Double(power)))
            if size >= factor, size % factor == 0 { return "\(size / factor)\(unit)" }
        }
        return String(size)
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    /// `2026-10-11` or `2026-10-11 09:58`. A day without a time means its start, or with
    /// `endOfDay` its last second, so that "to 2026-10-11" includes that day.
    static func date(from text: String, endOfDay: Bool = false) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if let date = formatter("yyyy-MM-dd HH:mm").date(from: text) { return date }
        guard let day = formatter("yyyy-MM-dd").date(from: text) else { return nil }
        return endOfDay ? day.addingTimeInterval(86_399) : day
    }

    static func text(ofDate date: Date?) -> String {
        date.map(formatter("yyyy-MM-dd HH:mm").string(from:)) ?? ""
    }
}

/// A mask or a selection type, ready to be asked which entries of a list it selects.
/// A value without shared state; `names` may run on any thread.
struct SelectionRule {
    let mask: SelectionMask
    let type: SelectionType?

    init(mask text: String) {
        mask = SelectionMask(text)
        type = nil
    }

    init(_ type: SelectionType) {
        mask = SelectionMask(type.mask)
        self.type = type
    }

    /// The names of the entries the rule selects, as a set (two names that read the same are
    /// one member; use `matching` where each entry counts).
    func names(among items: [FileItem], base: URL, now: Date = Date()) -> Set<String> {
        Set(matching(among: items, base: base, now: now))
    }

    /// The names of the entries the rule selects, one per entry in list order, written as the
    /// entries have them. `base` is the directory the list belongs to; path-limited masks are
    /// read relative to it.
    func matching(among items: [FileItem], base: URL, now: Date = Date()) -> [String] {
        matching(among: items, base: base, now: now, cancelled: { false })
    }

    /// The same, ending early once `cancelled` says so (the names found so far are then of no
    /// use). Whether a regular expression of the mask ran out of time is told by `mask.timedOut`.
    func matching(among items: [FileItem], base: URL, now: Date = Date(), cancelled: () -> Bool) -> [String] {
        matchingIndices(among: items, base: base, now: now, cancelled: cancelled).map { items[$0].name }
    }

    /// Whether the rule looks at other entries than the one it judges (`A>B` takes the files
    /// that belong to the matching ones): such a rule has to be run over the whole list.
    var isPairwise: Bool { mask.pairsRelatedFiles }

    /// The same as places in `items`, of the entries `scope` lets through.
    func matchingIndices(
        among items: [FileItem], base: URL, now: Date = Date(), scope: SelectionScope = .both,
        cancelled: () -> Bool
    ) -> [Int] {
        let entry = entryMaker(base: base)
        let entries = items.map(entry)
        var found: [Int] = []
        for (index, isSelected) in mask.selected(entries, cancelled: cancelled).enumerated()
        where isSelected && scope.contains(items[index]) && (type?.accepts(items[index], now: now) ?? true) {
            found.append(index)
        }
        return found
    }

    /// Whether the rule selects one entry on its own, for a rule that is not `isPairwise`. A
    /// function of the entry alone, so it may be asked from several threads at once.
    func probe(base: URL, now: Date = Date()) -> (FileItem) -> Bool {
        let (mask, type, entry) = (self.mask, self.type, entryMaker(base: base))
        return { item in mask.matches(entry(item)) && (type?.accepts(item, now: now) ?? true) }
    }

    /// What a mask is asked about an entry: `base` is the directory the list belongs to.
    private func entryMaker(base: URL) -> (FileItem) -> MaskEntry {
        let needsDirectories = mask.needsDirectories
        let baseParts = needsDirectories ? base.pathComponents.filter { $0 != "/" } : []
        return { item in
            // A list gathered from elsewhere (a branch view, a search result) names its entries
            // by path; the mask is tried against the file's own name, and the selection is
            // still keyed by the entry's name, which is unique in such a list.
            let name = item.name.utf8.contains(UInt8(ascii: "/")) ? item.url.lastPathComponent : item.name
            guard needsDirectories else { return MaskEntry(name: name, isFolder: item.isFolder) }
            let parts = item.url.deletingLastPathComponent().pathComponents.filter { $0 != "/" }
            // Entries of a list gathered from elsewhere (a search result) keep their whole path.
            let directory = parts.starts(with: baseParts) ? Array(parts.dropFirst(baseParts.count)) : parts
            return MaskEntry(name: name, isFolder: item.isFolder, directory: directory)
        }
    }
}

/// What the Mark menu remembers between sessions: the masks typed into Select group, the
/// predefined selection types and the options of the configuration page. Main thread only.
final class SelectionStore {
    static let historyLimit = 20
    static let scope = "selection"
    /// Full settings keys of the options, as the configuration dialog writes them.
    static let marksFoldersKey = scope + ".markDirectories"
    static let oneHourKey = scope + ".oneHourDifference"

    private let settings: SettingsStore
    private let scoped: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
        scoped = settings.scoped(to: Self.scope)
    }

    /// Whether Num +, Ctrl+Num + and Num * also affect folders (`MarkDirectories`).
    var marksFolders: Bool { settings.flag(Self.marksFoldersKey, default: true) }
    /// Whether comparing treats times exactly one hour apart as equal (`1hourdif`).
    var ignoresOneHour: Bool { settings.flag(Self.oneHourKey, default: false) }

    /// The masks used so far, the newest first.
    var history: [String] { scoped.value([String].self, forKey: "maskHistory") ?? [] }

    func remember(_ mask: String) {
        var masks = history.filter { $0 != mask }
        masks.insert(mask, at: 0)
        scoped.set(Array(masks.prefix(Self.historyLimit)), forKey: "maskHistory")
    }

    func forget(mask: String) {
        scoped.set(history.filter { $0 != mask }, forKey: "maskHistory")
    }

    var types: [SelectionType] { scoped.value([SelectionType].self, forKey: "types") ?? [] }

    func type(named name: String) -> SelectionType? {
        types.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Saves a type; one of the same name is replaced.
    func save(_ type: SelectionType) {
        var all = types
        if let index = all.firstIndex(where: { $0.name.caseInsensitiveCompare(type.name) == .orderedSame }) {
            all[index] = type
        } else {
            all.append(type)
        }
        scoped.set(all, forKey: "types")
    }

    func removeType(named name: String) {
        scoped.set(types.filter { $0.name.caseInsensitiveCompare(name) != .orderedSame }, forKey: "types")
    }
}
