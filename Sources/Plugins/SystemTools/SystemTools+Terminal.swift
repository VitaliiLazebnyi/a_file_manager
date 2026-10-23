import AFMKernel
import Foundation

/// Opening a terminal window (spec 12 › Miscellaneous commands, "Open command prompt window").
extension SystemTools {
    /// Finds an application by path, name or bundle identifier (`identified`).
    ///
    /// Asks the disk: background only.
    nonisolated internal static func application(named name: String, identified: (String) -> URL?) -> URL? {
        let files = FileManager.default
        if name.contains("/") {
            let path = TypedCommand.expandingTilde(in: name)
            return files.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let bundleName = name.lowercased().hasSuffix(".app") ? name : name + ".app"
        let candidates = TypedCommand.applicationFolders.map { folder in folder.appendingPathComponent(bundleName) }
        if let found = candidates.first(where: { candidate in files.fileExists(atPath: candidate.path) }) {
            return found
        }
        return identified(name)
    }

    /// Opens a terminal window in `directory`, with the terminal chosen in the preferences.
    internal func openTerminal(in directory: URL) {
        let name = settings.text(SystemToolsPlugin.terminalKey, default: "Terminal")
        let identified = desktop.applicationWithIdentifier
        // (Looking an application up asks the disk: on a thread of the kernel's own.)
        BlockingCalls.run { [weak self] in
            let application = Self.application(
                named: name.trimmingCharacters(in: .whitespaces),
                identified: identified
            )
            // Weak: the plugin may have gone by the time the disk has answered.
            DispatchQueue.main.async { [weak self] in self?.open(directory, inTerminal: application, named: name) }
        }
    }

    /// Opens `directory` in the terminal `application` that was looked up, or says that the one
    /// called `name` was not found.
    private func open(_ directory: URL, inTerminal application: URL?, named name: String) {
        guard let application else {
            interaction.inform(
                "The terminal application \(DisplayText.oneLine(name, limit: 120)) was not found.",
                detail: "Choose another one in the configuration.",
                style: .warning
            )
            return
        }
        note("terminal: \(DisplayText.oneLine(directory.path, limit: 200))")
        // A terminal that is handed a folder opens a window there.
        desktop.open([directory], application)
    }
}
