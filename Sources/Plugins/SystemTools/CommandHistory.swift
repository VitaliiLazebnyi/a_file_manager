import AFMKernel

/// The lines the user ran, newest first (spec 02 › Limits and persistence: 20 entries).
internal enum CommandHistory {
    /// How many lines are kept.
    internal static let limit = 20
    /// The settings key the lines are stored under.
    internal static let key = "history"

    /// The lines stored in `settings`, newest first; none when nothing is stored.
    internal static func load(from settings: any SettingsStore) -> [String] {
        settings.value([String].self, forKey: key) ?? []
    }

    /// A line typed with a blank in front is not remembered, as in a shell: the way to run
    /// something with a password in it without leaving it in the settings.
    internal static func isPrivate(_ line: String) -> Bool {
        line.unicodeScalars.first == " " || line.unicodeScalars.first == "\t"
    }

    /// Puts `line` first; an earlier occurrence of the same line goes.
    internal static func adding(_ line: String, to history: [String]) -> [String] {
        Array(([line] + history.filter { $0 != line }).prefix(limit))
    }
}
