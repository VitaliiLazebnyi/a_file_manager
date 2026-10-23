/// What an export holds.
internal struct SettingsExportOptions: Equatable {
    /// What is left out without `includesHistory`, as the user is told it.
    internal static let historyNote = "typed command lines, visited folders, search texts and other histories"
    /// What is left out without `includesConnections`, as the user is told it.
    internal static let connectionsNote = "saved connections (servers and user names) and trusted certificates"

    /// Typed command lines, visited folders, search texts.
    internal var includesHistory = false
    /// Saved connections (servers and user names) and the certificates trusted for them.
    internal var includesConnections = false

    /// The keys of `keys` that go into the file.
    internal func included(_ keys: [String], schema: SettingsSchema) -> [String] {
        keys.filter { key in
            if schema.isBackup(key) {
                return false
            }
            if schema.isConnectionData(key) {
                return includesConnections
            }
            if schema.isHistory(key) {
                return includesHistory
            }
            return true
        }
    }

    /// What is told about the file, before or after it is written.
    internal func description(count: Int) -> String {
        var left: [String] = []
        if !includesHistory { left.append(Self.historyNote) }
        if !includesConnections { left.append(Self.connectionsNote) }
        var text =
            "The file holds \(count) settings: the options of all pages, the key bindings, the button bar, "
            + "the user commands, the Start menu, the directory hotlist and the panels' tabs. "
            + "Passwords are never in it. Only you can read the file."
        if !left.isEmpty { text += "\nLeft out: " + left.joined(separator: "; ") + "." }
        return text
    }
}
