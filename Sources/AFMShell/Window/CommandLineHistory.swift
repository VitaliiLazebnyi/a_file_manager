import AFMKernel
import Foundation

/// The lines the user ran, newest first.
///
/// Spec 02 › Limits and persistence: up to 20 entries, kept between sessions. Main thread only.
///
/// A line may hold a password (`curl -u name:secret`). Two rules keep such a line out of the
/// settings, the same two the plugin that runs the lines has for its own history: a line that
/// begins with a blank is not remembered, as in a shell, and remembering can be switched off
/// altogether (`recordKey`, the plugin's switch, so there is one switch for both). Switched
/// off, what was remembered goes too.
@MainActor
internal final class CommandLineHistory {
    /// Settings key of the lines.
    internal static let settingsKey = "window.commandLineHistory"
    /// "Remember the command lines that were run", as the command-line plugin names it.
    internal static let recordKey = "systemTools.recordHistory"
    /// The most lines kept.
    internal static let limit = 20

    /// The lines, newest first.
    internal private(set) var entries: [String]
    /// Where the lines are kept.
    private let settings: any SettingsStore

    /// Whether lines are remembered at all.
    internal var isRecording: Bool { settings.flag(Self.recordKey, default: true) }

    /// The history kept in `settings`; forgotten at once when remembering is off.
    internal init(settings: any SettingsStore) {
        self.settings = settings
        entries = Array((settings.value([String].self, forKey: Self.settingsKey) ?? []).prefix(Self.limit))
        forgetIfSwitchedOff()
    }

    /// A line that is not for the history: it begins with a blank.
    internal static func isPrivate(_ line: String) -> Bool {
        line.unicodeScalars.first == " " || line.unicodeScalars.first == "\t"
    }

    /// Drops everything that was remembered when remembering was switched off since.
    ///
    /// Returns true when it is off.
    @discardableResult
    internal func forgetIfSwitchedOff() -> Bool {
        guard !isRecording else {
            return false
        }
        if !entries.isEmpty || settings.data(forKey: Self.settingsKey) != nil {
            entries = []
            settings.set(nil as Data?, forKey: Self.settingsKey)
        }
        return true
    }

    /// Remembers a line that was run; one that is run again moves to the front instead of
    /// appearing twice.
    ///
    /// `line` is the line as it was typed, with the blank it may begin with.
    internal func add(_ line: String) {
        guard !forgetIfSwitchedOff(), !Self.isPrivate(line) else {
            return
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return
        }
        entries.removeAll { $0 == trimmed }
        entries.insert(trimmed, at: 0)
        entries = Array(entries.prefix(Self.limit))
        settings.set(entries, forKey: Self.settingsKey)
    }

    deinit {
        // Nothing to release.
    }
}
