import AFMKernel
import Foundation

/// The settings the configuration plugin keeps for itself.
internal final class ConfigurationStore {
    /// The part of the settings the plugin owns: its keys start with `configuration.`.
    internal static let owner = "configuration"
    /// The key of the user commands, a list of `UserCommand`.
    internal static let userCommandsKey = "userCommands"
    /// The key of the Start menu, a list of `StartMenuEntry`.
    internal static let startMenuKey = "startMenu"
    /// The key of the pictures the user gave to commands.
    internal static let symbolsKey = "symbols"
    /// The full keys, for export and reset.
    internal static let keys = [userCommandsKey, startMenuKey, symbolsKey].map { owner + "." + $0 }
    /// The most entries that are used of a stored list: each is a command of the program and
    /// an item of a menu, and stored data may hold any number.
    internal static let startMenuLimit = 500
    /// The most user commands that are used of the stored list, for the same reason.
    internal static let userCommandLimit = 2_000

    private let settings: any SettingsStore
    /// What was decoded last, until the stored value is written or replaced: user commands are
    /// looked up per row and keystroke of the command browser.
    private var loadedUserCommands: [UserCommand] = [] {
        didSet { userCommandPlaces = [:] }
    }
    /// Whether `loadedUserCommands` holds what is stored.
    private var userCommandsLoaded = false
    /// The place of each user command by its name, made when one is first asked for by name
    /// (the menus ask for every command on each validation, which must not search the list).
    private var userCommandPlaces: [String: Int] = [:]
    /// What was decoded last of the Start menu.
    private var loadedStartMenu: [StartMenuEntry] = []
    /// Whether `loadedStartMenu` holds what is stored.
    private var startMenuLoaded = false
    /// Told, on the main thread, that stored data could not be read in full and was kept aside.
    internal var onProblem: (@MainActor @Sendable (String) -> Void)?

    /// The user commands, at most `userCommandLimit`; setting them stores them.
    internal var userCommands: [UserCommand] {
        get {
            if !userCommandsLoaded {
                loadedUserCommands = Array(
                    load(UserCommand.self, key: Self.userCommandsKey, what: "user commands")
                        .prefix(Self.userCommandLimit)
                )
                userCommandsLoaded = true
            }
            return loadedUserCommands
        }
        set {
            loadedUserCommands = newValue
            userCommandsLoaded = true
            settings.set(newValue, forKey: Self.userCommandsKey)
        }
    }

    /// The entries of the Start menu, at most `startMenuLimit`; setting them stores them.
    internal var startMenu: [StartMenuEntry] {
        get {
            if !startMenuLoaded {
                loadedStartMenu = Array(
                    load(StartMenuEntry.self, key: Self.startMenuKey, what: "Start menu")
                        .prefix(Self.startMenuLimit)
                )
                startMenuLoaded = true
            }
            return loadedStartMenu
        }
        set {
            loadedStartMenu = newValue
            startMenuLoaded = true
            settings.set(newValue, forKey: Self.startMenuKey)
        }
    }

    /// The pictures the user gave to commands: command name → system symbol.
    internal var symbols: [String: String] {
        get { settings.value([String: String].self, forKey: Self.symbolsKey) ?? [:] }
        set { settings.set(newValue, forKey: Self.symbolsKey) }
    }

    /// The store over the plugin's part of `settings`.
    internal init(settings: any SettingsStore) {
        self.settings = settings.scoped(to: Self.owner)
    }

    /// Forgets what was decoded: the settings were replaced behind the store's back (import, reset).
    internal func invalidate() {
        userCommandsLoaded = false
        userCommandPlaces = [:]
        startMenuLoaded = false
    }

    /// The user command of this name; the first of that name, as a search of the list finds it.
    internal func userCommand(named name: String) -> UserCommand? {
        let commands = userCommands
        // An empty list has nothing to find, so making its empty table again costs nothing.
        if userCommandPlaces.isEmpty {
            var places: [String: Int] = [:]
            for (index, command) in commands.enumerated() where places[command.name] == nil {
                places[command.name] = index
            }
            userCommandPlaces = places
        }
        return userCommandPlaces[name].map { commands[$0] }
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
            list.map { "\($0.skipped) of the stored \(what) could not be read and were left out." }
            ?? "The stored \(what) could not be read."
        let report = onProblem
        MainLoop.perform {
            report?(message + " The original data is kept in the setting “\(Self.owner).\(backup)”.")
        }
        return list?.elements ?? []
    }

    deinit {
        // Nothing to release.
    }
}
