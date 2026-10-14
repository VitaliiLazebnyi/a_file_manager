import AFMKernel
import Foundation

/// A page of the Options window while it is open (spec 13 › The dialog framework): the values
/// the user sees, which reach the settings only with Apply or OK. Main thread only.
final class PreferencePageModel {
    let page: PreferencePage
    private let settings: SettingsStore
    private var stored: [String: FormValues.Value] = [:]
    private var pending: [String: FormValues.Value] = [:]

    init(page: PreferencePage, settings: SettingsStore) {
        self.page = page
        self.settings = settings
        discard()
    }

    var title: String { page.title }

    func value(of preference: Preference) -> FormValues.Value {
        pending[preference.key] ?? settings.value(of: preference)
    }

    func set(_ value: FormValues.Value, for preference: Preference) {
        pending[preference.key] = value
    }

    var isChanged: Bool { pending != stored }

    /// Apply: writes what was changed and tells the page's plugin, once, if anything was.
    func commit() {
        let changed = page.preferences.filter { pending[$0.key] != stored[$0.key] }
        guard !changed.isEmpty else { return }
        for preference in changed {
            if let value = pending[preference.key] { settings.set(value, for: preference) }
        }
        stored = pending
        page.onChange()
    }

    /// Cancel: back to what the settings hold.
    func discard() {
        stored = [:]
        for preference in page.preferences { stored[preference.key] = settings.value(of: preference) }
        pending = stored
    }
}

/// A stored list read element by element: an element that cannot be decoded is counted and
/// skipped, so one bad entry (or a field a later version added) does not take the rest along.
struct LenientList<Element: Decodable>: Decodable {
    private struct Ignored: Decodable { init(from decoder: Decoder) throws {} }

    var elements: [Element] = []
    var skipped = 0

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                skipped += 1
                _ = try container.decode(Ignored.self)
            }
        }
    }
}

/// The settings the configuration plugin keeps for itself.
final class ConfigurationStore {
    static let owner = "configuration"
    static let userCommandsKey = "userCommands"
    static let startMenuKey = "startMenu"
    static let symbolsKey = "symbols"
    /// The full keys, for export and reset.
    static let keys = [userCommandsKey, startMenuKey, symbolsKey].map { owner + "." + $0 }
    /// The most entries that are used of a stored list: each is a command of the program and
    /// an item of a menu, and stored data may hold any number.
    static let startMenuLimit = 500
    static let userCommandLimit = 2000

    private let settings: SettingsStore
    /// What was decoded last, until the stored value is written or replaced: user commands are
    /// looked up per row and keystroke of the command browser.
    private var cachedUserCommands: [UserCommand]? {
        didSet { userCommandPlaces = nil }
    }
    /// The place of each user command by its name, made when one is first asked for by name
    /// (the menus ask for every command on each validation, which must not search the list).
    private var userCommandPlaces: [String: Int]?
    private var cachedStartMenu: [StartMenuEntry]?
    /// Told, on the main thread, that stored data could not be read in full and was kept aside.
    var onProblem: ((String) -> Void)?

    init(settings: SettingsStore) {
        self.settings = settings.scoped(to: ConfigurationStore.owner)
    }

    /// Forgets what was decoded: the settings were replaced behind the store's back (import, reset).
    func invalidate() {
        cachedUserCommands = nil
        cachedStartMenu = nil
    }

    /// The user command of this name; the first of that name, as a search of the list finds it.
    func userCommand(named name: String) -> UserCommand? {
        let commands = userCommands
        if userCommandPlaces == nil {
            var places: [String: Int] = [:]
            for (index, command) in commands.enumerated() where places[command.name] == nil { places[command.name] = index }
            userCommandPlaces = places
        }
        return userCommandPlaces?[name].map { commands[$0] }
    }

    var userCommands: [UserCommand] {
        get {
            if let cachedUserCommands { return cachedUserCommands }
            let loaded = Array(load(UserCommand.self, key: ConfigurationStore.userCommandsKey, what: "user commands").prefix(ConfigurationStore.userCommandLimit))
            cachedUserCommands = loaded
            return loaded
        }
        set {
            cachedUserCommands = newValue
            settings.set(newValue, forKey: ConfigurationStore.userCommandsKey)
        }
    }

    var startMenu: [StartMenuEntry] {
        get {
            if let cachedStartMenu { return cachedStartMenu }
            let loaded = Array(load(StartMenuEntry.self, key: ConfigurationStore.startMenuKey, what: "Start menu").prefix(ConfigurationStore.startMenuLimit))
            cachedStartMenu = loaded
            return loaded
        }
        set {
            cachedStartMenu = newValue
            settings.set(newValue, forKey: ConfigurationStore.startMenuKey)
        }
    }

    /// The list stored under `key`, element by element. When the data is not a list, or has
    /// elements that cannot be read, a copy of it is kept under `<key>.unreadable` before
    /// anything else is saved over it, and the user is told. A copy kept from an earlier time
    /// moves to `<key>.unreadable.previous`, so the newest two are there. The copies are not
    /// exported; Reset All Settings removes them.
    private func load<Element: Decodable>(_ type: Element.Type, key: String, what: String) -> [Element] {
        guard let data = settings.data(forKey: key) else { return [] }
        let list = try? JSONDecoder().decode(LenientList<Element>.self, from: data)
        if let list, list.skipped == 0 { return list.elements }
        let backup = key + ".unreadable"
        if let earlier = settings.data(forKey: backup), earlier != data { settings.set(earlier as Data?, forKey: backup + ".previous") }
        settings.set(data as Data?, forKey: backup)
        let message = list == nil ? "The stored \(what) could not be read." : "\(list!.skipped) of the stored \(what) could not be read and were left out."
        MainLoop.perform { [onProblem] in onProblem?(message + " The original data is kept in the setting “\(ConfigurationStore.owner).\(backup)”.") }
        return list?.elements ?? []
    }

    /// The pictures the user gave to commands: command name → system symbol.
    var symbols: [String: String] {
        get { settings.value([String: String].self, forKey: ConfigurationStore.symbolsKey) ?? [:] }
        set { settings.set(newValue, forKey: ConfigurationStore.symbolsKey) }
    }
}

/// The button bar while it is being edited (spec 14 › Button bars, The Change button bar
/// dialog): a list of commands and separators. Nothing changes outside until `commit`.
/// Main thread only.
///
/// The bar holds commands of the program only; a program with parameters goes on the bar as a
/// user command, which is what Total Commander's `em_` commands are for.
final class ToolbarEditor {
    private let toolbar: ToolbarRegistry
    private let settings: SettingsStore
    private let store: ConfigurationStore
    /// The bar in order; nil is a separator.
    private(set) var items: [CommandID?] = []
    /// The pictures the user chose, by command name.
    private(set) var symbols: [String: String] = [:]
    /// The bar is the plugins' proposal, not a layout of the user's own.
    private(set) var isDefault = true
    private(set) var isChanged = false

    init(toolbar: ToolbarRegistry, settings: SettingsStore, store: ConfigurationStore) {
        self.toolbar = toolbar
        self.settings = settings
        self.store = store
        discard()
    }

    func discard() {
        items = toolbar.layout(from: settings).map { $0?.command }
        isDefault = settings.data(forKey: ToolbarRegistry.settingsKey) == nil
        symbols = store.symbols
        isChanged = false
    }

    private func edited() {
        isDefault = false
        isChanged = true
    }

    /// Inserts directly after `row` (at the end without one) and returns the new row.
    @discardableResult
    func insert(_ command: CommandID?, after row: Int?) -> Int {
        let index = row.map { min($0 + 1, items.count) } ?? items.count
        items.insert(command, at: max(0, index))
        edited()
        return index
    }

    func remove(at row: Int) {
        guard items.indices.contains(row) else { return }
        items.remove(at: row)
        edited()
    }

    /// Moves a row up (-1) or down (+1); returns where it is afterwards.
    @discardableResult
    func move(_ row: Int, by offset: Int) -> Int {
        let target = row + offset
        guard items.indices.contains(row), items.indices.contains(target) else { return row }
        items.swapAt(row, target)
        edited()
        return target
    }

    func resetToDefault() {
        items = toolbar.defaultLayout.map { $0?.command }
        isDefault = true
        isChanged = true
    }

    /// The symbol shown for a command: the user's, else the one its plugin gave it.
    func symbol(for command: CommandID) -> String {
        symbols[command.rawValue] ?? toolbar.symbol(for: command) ?? "square.dashed"
    }

    /// An empty name takes the user's picture away again.
    func setSymbol(_ symbol: String, for command: CommandID) {
        symbols[command.rawValue] = symbol.isEmpty ? nil : symbol
        isChanged = true
    }

    func commit() {
        guard isChanged else { return }
        store.symbols = symbols
        for (name, symbol) in symbols { toolbar.setSymbol(symbol, for: CommandID(rawValue: name)) }
        // Storing the layout also has the bar drawn again, with the new pictures.
        toolbar.setLayout(isDefault ? nil : items, in: settings)
        isChanged = false
    }
}

/// The Start menu while it is being edited (spec 14 › The Change start menu dialog). Each
/// entry carries its shortcut as text; the keys themselves live in the key bindings.
struct StartMenuDraft: Equatable {
    struct Row: Equatable {
        var entry: StartMenuEntry
        /// The shortcut as the user wrote it; empty for none.
        var shortcut = ""
    }

    var rows: [Row] = []

    @discardableResult
    mutating func insert(_ row: Row, after index: Int?) -> Int {
        let position = index.map { min($0 + 1, rows.count) } ?? rows.count
        rows.insert(row, at: max(0, position))
        return position
    }

    @discardableResult
    mutating func move(_ index: Int, by offset: Int) -> Int {
        let target = index + offset
        guard rows.indices.contains(index), rows.indices.contains(target) else { return index }
        rows.swapAt(index, target)
        return target
    }
}

/// Settings written to a file and read back (the Mac's stand-in for copying `wincmd.ini`;
/// spec 19 › What is saved when). A value is kept as the JSON it is stored as, so the file
/// can be read and changed by hand.
struct SettingsArchive: Equatable {
    static let format = "A File Manager settings"

    enum ArchiveError: LocalizedError {
        case notAnArchive
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .notAnArchive: "This is not a settings file of this program."
            case .unreadable(let key): "The value of “\(key)” in this file cannot be read, so nothing was imported."
            }
        }
    }

    var values: [String: Data] = [:]

    /// What the store holds under the given keys; keys without a value are left out.
    static func capture(from settings: SettingsStore, keys: [String]) -> SettingsArchive {
        var archive = SettingsArchive()
        for key in keys { archive.values[key] = settings.data(forKey: key) }
        return archive
    }

    /// Makes the store hold what the archive holds. Of `knownKeys`, those the archive lacks
    /// are removed, so an import brings back the state at export, not a mixture.
    func restore(into settings: SettingsStore, replacing knownKeys: [String]) {
        for key in knownKeys where values[key] == nil { settings.set(nil as Data?, forKey: key) }
        for (key, value) in values { settings.set(value as Data?, forKey: key) }
    }

    /// Checks the values whose shape is known against it, so that a damaged file is refused
    /// before it replaces working settings.
    func validate(keyBindingsKey: String) throws {
        func check<Value: Decodable>(_ key: String, _ type: Value.Type, valid: (Value) -> Bool = { _ in true }) throws {
            guard let data = values[key] else { return }
            guard let value = try? JSONDecoder().decode(type, from: data), valid(value) else { throw ArchiveError.unreadable(key) }
        }
        try check(ConfigurationStore.owner + "." + ConfigurationStore.userCommandsKey, LenientList<UserCommand>.self) { $0.skipped == 0 }
        try check(ConfigurationStore.owner + "." + ConfigurationStore.startMenuKey, LenientList<StartMenuEntry>.self) { $0.skipped == 0 }
        try check(ConfigurationStore.owner + "." + ConfigurationStore.symbolsKey, [String: String].self)
        try check(keyBindingsKey, [String: [String]].self)
    }

    func encoded() throws -> Data {
        var entries: [String: Any] = [:]
        for (key, data) in values {
            entries[key] = (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) ?? ["$data": data.base64EncodedString()]
        }
        let file: [String: Any] = ["format": SettingsArchive.format, "version": 1, "settings": entries]
        return try JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys])
    }

    init() {}

    init(data: Data) throws {
        guard let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any], file["format"] as? String == SettingsArchive.format,
              let entries = file["settings"] as? [String: Any] else { throw ArchiveError.notAnArchive }
        for (key, value) in entries {
            if let wrapped = value as? [String: Any], wrapped.count == 1, let text = wrapped["$data"] as? String, let raw = Data(base64Encoded: text) {
                values[key] = raw
            } else if let json = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) {
                values[key] = json
            }
        }
    }
}
