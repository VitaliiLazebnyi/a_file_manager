import Foundation
import os

/// What kind of thing a settings key holds, for whoever exports or imports settings.
public enum SettingsKeyKind: Sendable {
    /// A preference or a piece of state.
    case ordinary
    /// What the user did (lines typed, folders visited): left out of exports.
    case history
    /// Holds something that is run (a command line, a program to start): taken from a file
    /// only when the user says so.
    case runsCode
    /// Decides whom the program trusts (a server's certificate or key).
    case trust
    /// The address and account of a server.
    case connection
}
