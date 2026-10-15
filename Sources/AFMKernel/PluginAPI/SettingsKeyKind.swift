/// What kind of thing a settings key holds, for whoever exports or imports settings.
public enum SettingsKeyKind: Sendable {
    /// The address and account of a server.
    case connection
    /// What the user did (lines typed, folders visited): left out of exports.
    case history
    /// A preference or a piece of state.
    case ordinary
    /// Holds something that is run (a command line, a program to start): taken from a file
    /// only when the user says so.
    case runsCode
    /// Decides whom the program trusts (a server's certificate or key).
    case trust
}
