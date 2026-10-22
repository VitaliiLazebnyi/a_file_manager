import AFMKernel
import Foundation

/// A page of the Options window while it is open (spec 13 › The dialog framework): the values
/// the user sees, which reach the settings only with Apply or OK. Main thread only.
@MainActor
internal final class PreferencePageModel {
    internal let page: PreferencePage
    private let settings: any SettingsStore
    private var stored: [String: FormValues.Value] = [:]
    private var pending: [String: FormValues.Value] = [:]

    internal init(page: PreferencePage, settings: any SettingsStore) {
        self.page = page
        self.settings = settings
        discard()
    }

    internal var title: String { page.title }

    internal func value(of preference: Preference) -> FormValues.Value {
        pending[preference.key] ?? settings.value(of: preference)
    }

    internal func set(_ value: FormValues.Value, for preference: Preference) {
        pending[preference.key] = value
    }

    internal var isChanged: Bool { pending != stored }

    /// Apply: writes what was changed and tells the page's plugin, once, if anything was.
    internal func commit() {
        let changed = page.preferences.filter { pending[$0.key] != stored[$0.key] }
        guard !changed.isEmpty else {
            return
        }
        for preference in changed {
            if let value = pending[preference.key] { settings.set(value, for: preference) }
        }
        stored = pending
        page.onChange()
    }

    /// Cancel: back to what the settings hold.
    internal func discard() {
        stored = [:]
        for preference in page.preferences { stored[preference.key] = settings.value(of: preference) }
        pending = stored
    }
}

/// A stored list read element by element: an element that cannot be decoded is counted and
/// skipped, so one bad entry (or a field a later version added) does not take the rest along.
internal struct LenientList<Element: Decodable>: Decodable {
    private struct Ignored: Decodable { init(from _: any Decoder) {} }

    internal var elements: [Element] = []
    internal var skipped = 0

    internal init(from decoder: any Decoder) throws {
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
internal final class ConfigurationStore {
    internal static let owner = "configuration"
    internal static let userCommandsKey = "userCommands"
    internal static let startMenuKey = "startMenu"
    internal static let symbolsKey = "symbols"
    /// The full keys, for export and reset.
    internal static let keys = [userCommandsKey, startMenuKey, symbolsKey].map { owner + "." + $0 }
    /// The most entries that are used of a stored list: each is a command of the program and
    /// an item of a menu, and stored data may hold any number.
    internal static let startMenuLimit = 500
    internal static let userCommandLimit = 2_000

    private let settings: any SettingsStore
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
    internal var onProblem: (@MainActor @Sendable (String) -> Void)?

    internal init(settings: any SettingsStore) {
        self.settings = settings.scoped(to: Self.owner)
    }

    /// Forgets what was decoded: the settings were replaced behind the store's back (import, reset).
    internal func invalidate() {
        cachedUserCommands = nil
        cachedStartMenu = nil
    }

    /// The user command of this name; the first of that name, as a search of the list finds it.
    internal func userCommand(named name: String) -> UserCommand? {
        let commands = userCommands
        if userCommandPlaces == nil {
            var places: [String: Int] = [:]
            for (index, command) in commands.enumerated() where places[command.name] == nil {
                places[command.name] = index
            }
            userCommandPlaces = places
        }
        return userCommandPlaces?[name].map { commands[$0] }
    }

    internal var userCommands: [UserCommand] {
        get {
            if let cachedUserCommands {
                return cachedUserCommands
            }
            let loaded = Array(
                load(UserCommand.self, key: Self.userCommandsKey, what: "user commands")
                    .prefix(
                        Self.userCommandLimit
                    )
            )
            cachedUserCommands = loaded
            return loaded
        }
        set {
            cachedUserCommands = newValue
            settings.set(newValue, forKey: Self.userCommandsKey)
        }
    }

    internal var startMenu: [StartMenuEntry] {
        get {
            if let cachedStartMenu {
                return cachedStartMenu
            }
            let loaded = Array(
                load(StartMenuEntry.self, key: Self.startMenuKey, what: "Start menu")
                    .prefix(
                        Self.startMenuLimit
                    )
            )
            cachedStartMenu = loaded
            return loaded
        }
        set {
            cachedStartMenu = newValue
            settings.set(newValue, forKey: Self.startMenuKey)
        }
    }

    /// The list stored under `key`, element by element.
    ///
    /// When the data is not a list, or has elements that cannot be read, a copy of it is kept under
    /// `<key>.unreadable` before anything else is saved over it, and the user is told. A copy kept
    /// from an earlier time moves to `<key>.unreadable.previous`, so the newest two are there. The
    /// copies are not exported; Reset All Settings removes them.
    private func load<Element: Decodable>(_: Element.Type, key: String, what: String) -> [Element] {
        guard let data = settings.data(forKey: key) else {
            return []
        }
        let list = try? JSONDecoder().decode(LenientList<Element>.self, from: data)
        if let list, list.skipped == 0 {
            return list.elements
        }
        let backup = key + ".unreadable"
        if let earlier = settings.data(forKey: backup), earlier != data {
            settings.set(earlier as Data?, forKey: backup + ".previous")
        }
        settings.set(data as Data?, forKey: backup)
        let message =
            list == nil
            ? "The stored \(what) could not be read."
            : "\(list!.skipped) of the stored \(what) could not be read and were left out."
        MainLoop.perform { [onProblem] in
            onProblem?(message + " The original data is kept in the setting “\(Self.owner).\(backup)”.")
        }
        return list?.elements ?? []
    }

    /// The pictures the user gave to commands: command name → system symbol.
    internal var symbols: [String: String] {
        get { settings.value([String: String].self, forKey: Self.symbolsKey) ?? [:] }
        set { settings.set(newValue, forKey: Self.symbolsKey) }
    }
}

/// The button bar while it is being edited (spec 14 › Button bars, The Change button bar
/// dialog): a list of commands and separators.
///
/// Nothing changes outside until `commit`. Main thread only.
///
/// The bar holds commands of the program only; a program with parameters goes on the bar as a
/// user command, which is what Total Commander's `em_` commands are for.
@MainActor
internal final class ToolbarEditor {
    private let toolbar: ToolbarRegistry
    private let settings: any SettingsStore
    private let store: ConfigurationStore
    /// The bar in order; nil is a separator.
    internal private(set) var items: [CommandID?] = []
    /// The pictures the user chose, by command name.
    internal private(set) var symbols: [String: String] = [:]
    /// The bar is the plugins' proposal, not a layout of the user's own.
    internal private(set) var isDefault = true
    internal private(set) var isChanged = false

    internal init(toolbar: ToolbarRegistry, settings: any SettingsStore, store: ConfigurationStore) {
        self.toolbar = toolbar
        self.settings = settings
        self.store = store
        discard()
    }

    internal func discard() {
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
    internal func insert(_ command: CommandID?, after row: Int?) -> Int {
        let index = row.map { min($0 + 1, items.count) } ?? items.count
        items.insert(command, at: max(0, index))
        edited()
        return index
    }

    internal func remove(at row: Int) {
        guard items.indices.contains(row) else {
            return
        }
        items.remove(at: row)
        edited()
    }

    /// Moves a row up (-1) or down (+1); returns where it is afterwards.
    @discardableResult
    internal func move(_ row: Int, by offset: Int) -> Int {
        let target = row + offset
        guard items.indices.contains(row), items.indices.contains(target) else {
            return row
        }
        items.swapAt(row, target)
        edited()
        return target
    }

    internal func resetToDefault() {
        items = toolbar.defaultLayout.map { $0?.command }
        isDefault = true
        isChanged = true
    }

    /// The symbol shown for a command: the user's, else the one its plugin gave it.
    internal func symbol(for command: CommandID) -> String {
        symbols[command.rawValue] ?? toolbar.symbol(for: command) ?? "square.dashed"
    }

    /// An empty name takes the user's picture away again.
    internal func setSymbol(_ symbol: String, for command: CommandID) {
        symbols[command.rawValue] = symbol.isEmpty ? nil : symbol
        isChanged = true
    }

    internal func commit() {
        guard isChanged else {
            return
        }
        store.symbols = symbols
        for (name, symbol) in symbols { toolbar.setSymbol(symbol, for: CommandID(rawValue: name)) }
        // Storing the layout also has the bar drawn again, with the new pictures.
        if isDefault {
            toolbar.resetLayout(in: settings)
        } else {
            toolbar.setLayout(items, in: settings)
        }
        isChanged = false
    }
}

/// The Start menu while it is being edited (spec 14 › The Change start menu dialog).
///
/// Each entry carries its shortcut as text; the keys themselves live in the key bindings.
internal struct StartMenuDraft: Equatable {
    internal struct Row: Equatable {
        internal var entry: StartMenuEntry
        /// The shortcut as the user wrote it; empty for none.
        internal var shortcut = ""
    }

    internal var rows: [Row] = []

    @discardableResult
    internal mutating func insert(_ row: Row, after index: Int?) -> Int {
        let position = index.map { min($0 + 1, rows.count) } ?? rows.count
        rows.insert(row, at: max(0, position))
        return position
    }

    @discardableResult
    internal mutating func move(_ index: Int, by offset: Int) -> Int {
        let target = index + offset
        guard rows.indices.contains(index), rows.indices.contains(target) else {
            return index
        }
        rows.swapAt(index, target)
        return target
    }
}

/// Settings written to a file and read back (the Mac's stand-in for copying `wincmd.ini`;
/// spec 19 › What is saved when).
///
/// A value is kept as the JSON it is stored as, so the file can be read and changed by hand.
internal struct SettingsArchive: Equatable {
    internal static let format = "A File Manager settings"

    internal enum ArchiveError: LocalizedError {
        case notAnArchive
        case unreadable(String)

        internal var errorDescription: String? {
            switch self {
            case .notAnArchive:
                "This is not a settings file of this program."

            case .unreadable(let key):
                "The value of “\(key)” in this file cannot be read, so nothing was imported."
            }
        }
    }

    internal var values: [String: Data] = [:]

    /// What the store holds under the given keys; keys without a value are left out.
    internal static func capture(from settings: any SettingsStore, keys: [String]) -> Self {
        var archive = Self()
        for key in keys { archive.values[key] = settings.data(forKey: key) }
        return archive
    }

    /// Makes the store hold what the archive holds.
    ///
    /// Of `knownKeys`, those the archive lacks are removed, so an import brings back the state at
    /// export, not a mixture.
    internal func restore(into settings: any SettingsStore, replacing knownKeys: [String]) {
        for key in knownKeys where values[key] == nil { settings.set(nil as Data?, forKey: key) }
        for (key, value) in values { settings.set(value as Data?, forKey: key) }
    }

    /// Checks the values whose shape is known against it, so that a damaged file is refused
    /// before it replaces working settings.
    internal func validate(keyBindingsKey: String) throws {
        func check<Value: Decodable>(_ key: String, _ type: Value.Type, valid: (Value) -> Bool = { _ in true }) throws {
            guard let data = values[key] else {
                return
            }
            guard let value = try? JSONDecoder().decode(type, from: data), valid(value) else {
                throw ArchiveError.unreadable(key)
            }
        }
        try check(ConfigurationStore.owner + "." + ConfigurationStore.userCommandsKey, LenientList<UserCommand>.self) {
            $0.skipped == 0
        }
        try check(ConfigurationStore.owner + "." + ConfigurationStore.startMenuKey, LenientList<StartMenuEntry>.self) {
            $0.skipped == 0
        }
        try check(ConfigurationStore.owner + "." + ConfigurationStore.symbolsKey, [String: String].self)
        try check(keyBindingsKey, [String: [String]].self)
    }

    internal func encoded() throws -> Data {
        var entries: [String: Any] = [:]
        for (key, data) in values {
            entries[key] =
                (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) ?? [
                    "$data": data.base64EncodedString()
                ]
        }
        let file: [String: Any] = ["format": Self.format, "version": 1, "settings": entries]
        return try JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys])
    }

    internal init() {}

    internal init(data: Data) throws {
        guard let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            file["format"] as? String == Self.format,
            let entries = file["settings"] as? [String: Any]
        else { throw ArchiveError.notAnArchive }
        for (key, value) in entries {
            if let wrapped = value as? [String: Any], wrapped.count == 1, let text = wrapped["$data"] as? String,
                let raw = Data(base64Encoded: text)
            {
                values[key] = raw
            } else if let json = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.fragmentsAllowed, .sortedKeys]
            ) {
                values[key] = json
            }
        }
    }
}
