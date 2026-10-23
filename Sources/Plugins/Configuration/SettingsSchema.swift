import AFMKernel
import Foundation

/// What the program knows about its settings, for deciding what a settings file may bring in
/// and what an export leaves out.
///
/// A plain value: made on the main thread, used on any.
internal struct SettingsSchema {
    // MARK: What an import asks about

    /// The parts of a settings file that can make the program run something, change what a
    /// key does, or change whom it trusts.
    ///
    /// Each is imported only when the user says so. The raw value names the part's checkbox in the import dialog;
    /// `allCases` is the order the dialog lists the parts in.
    internal enum Group: String, CaseIterable {
        /// The user commands and the Start menu.
        case commands = "commands"
        /// The key bindings.
        case keys = "keys"
        /// Settings that name a program or a file the program starts or writes to.
        case programs = "programs"
        /// Certificates accepted and servers a password may be sent to unprotected.
        case trust = "trust"
        /// The saved connections.
        case connections = "connections"
        /// The directory hotlist, whose entries can run commands.
        case hotlist = "hotlist"
        /// The panels' tabs that are on servers.
        case tabs = "tabs"
    }

    /// The corners of the settings the parts of the program keep their values in.
    ///
    /// A key of none of them is nobody's and is not imported.
    internal static let namespaces: Set<String> = [
        "window", "panel", "listingCache", "toolbar", "configuration", "systemTools", "viewOptions", "macIntegration",
        "folderTabs", "clipboard",
        "virtualFolders", "findFiles", "places", "network", "selection", "multirename", "directorySync",
        "compareContent", "filetools", "viewer",
        "archives", "fileOperations", "fileProperties"
    ]
    /// The keys of the two panels' tabs.
    internal static let tabKeys: Set<String> = ["left.tabs", "right.tabs"]
    /// The key of the user commands.
    internal static let userCommandsKey = ConfigurationStore.owner + "." + ConfigurationStore.userCommandsKey
    /// The key of the Start menu.
    internal static let startMenuKey = ConfigurationStore.owner + "." + ConfigurationStore.startMenuKey
    /// The key of the button bar's symbols.
    internal static let symbolsKey = ConfigurationStore.owner + "." + ConfigurationStore.symbolsKey
    /// The key of the visit counters of the frequently used folders.
    internal static let frequentFoldersKey = "places.history.frequent"
    /// The key of the directory hotlist.
    internal static let hotlistKey = "places.hotlist"
    /// The key of the saved connections.
    internal static let connectionsKey = "network.connections"
    /// The key of the number of the connection used last.
    internal static let lastConnectionKey = "network.lastUsed"

    /// The groups of the keys that belong to one by their name alone (the key bindings' key is the schema's own).
    private static let groupsByKey: [String: Group] = [
        userCommandsKey: .commands, startMenuKey: .commands, hotlistKey: .hotlist,
        connectionsKey: .connections, lastConnectionKey: .connections
    ]

    /// The options of the configuration pages, with their kinds.
    internal var preferences: [String: Preference.Kind] = [:]
    /// Keys the running program knows by name: its own, and those it has stored.
    internal var known: Set<String> = []
    /// The key the key bindings are stored under.
    internal var keyBindingsKey = KeyBindings.settingsKey
    /// What the plugin a key belongs to has said about it (`Kernel.settingsKeys`), nil for a
    /// key nobody declared.
    ///
    /// Asked before the names are looked at: a plugin knows what its key does, and a name gives it
    /// away only when it happens to hold the right word.
    internal var declaredKind: @Sendable (String) -> SettingsKeyKind? = { _ in nil }

    /// Tabs on this Mac's disks are ordinary; one on a server makes the program connect.
    private static func tabsGroup(_ value: Any?) -> Group? {
        guard let state = value as? [String: Any], let tabs = state["tabs"] as? [[String: Any]] else {
            return nil
        }
        let isRemote = tabs.contains { tab in
            (tab["location"] as? String).map { !$0.lowercased().hasPrefix("file:") } ?? false
        }
        return isRemote ? .tabs : nil
    }

    /// Whether a key is one of the program's: a page's option, a key it knows or stored, or a
    /// key in one of the `namespaces` (never a backup).
    internal func isKnown(_ key: String) -> Bool {
        if preferences[key] != nil || known.contains(key) || key == keyBindingsKey
            || Self.tabKeys.contains(key)
        {
            return true
        }
        guard !isBackup(key), let dot = key.firstIndex(of: "."),
            key[key.index(after: dot)...].contains(where: { $0 != "." })
        else { return false }
        return Self.namespaces.contains(String(key[..<dot]))
    }

    /// The copy the program keeps of stored data it could not read.
    ///
    /// It is neither exported nor imported.
    internal func isBackup(_ key: String) -> Bool { key.contains(".unreadable") }

    // MARK: What an export leaves out unless asked

    /// What the user did, as opposed to what the user set up: typed command lines, visited
    /// folders, search texts, the files renamed last.
    internal func isHistory(_ key: String) -> Bool {
        guard preferences[key] == nil else {
            return false
        }
        if declaredKind(key) == .history {
            return true
        }
        let lowered = key.lowercased()
        return lowered.contains("history") || lowered.contains("undo") || lowered.contains("lastserver")
    }

    /// Servers, user names and the certificates accepted for them.
    internal func isConnectionData(_ key: String) -> Bool {
        key == Self.connectionsKey || key == Self.lastConnectionKey
            || group(of: key, value: nil) == .trust
    }

    /// The group a key belongs to; nil for an ordinary setting.
    ///
    /// `value` is the value in the file, where the group depends on it.
    internal func group(of key: String, value: Any?) -> Group? {
        if key == keyBindingsKey {
            return .keys
        }
        if let group = Self.groupsByKey[key] ?? declaredGroup(of: key) {
            return group
        }
        let lowered = key.lowercased()
        if lowered.hasPrefix("network."), ["certificate", "trust", "tls"].contains(where: lowered.contains) {
            return .trust
        }
        if Self.tabKeys.contains(key) {
            return Self.tabsGroup(value)
        }
        return namesAProgram(key, lowered: lowered, value: value) ? .programs : nil
    }

    /// What its own plugin says a key is: a key that decides whom the program trusts is asked
    /// about whatever it is called (the list of servers a password may be sent to without
    /// protection has none of the words `group(of:value:)` looks for in its name), and so is one
    /// that holds something that is run.
    private func declaredGroup(of key: String) -> Group? {
        switch declaredKind(key) {
        case .trust:
            .trust

        case .connection:
            .connections

        case .runsCode:
            .programs

        default:
            nil
        }
    }

    /// Whether the value is a text that names a program, a command or a file the program then
    /// starts or writes to, by the last part of its key (`lowered`, the key in lower case).
    private func namesAProgram(_ key: String, lowered: String, value: Any?) -> Bool {
        guard value is String else {
            return false
        }
        let name = lowered.split(separator: ".").last.map(String.init) ?? lowered
        let namesAProgram = ["editor", "terminal", "program", "command", "tool", "shell", "exec", "path", "file"]
            .contains(where: name.contains)
        return namesAProgram && !isHistory(key)
    }
}
