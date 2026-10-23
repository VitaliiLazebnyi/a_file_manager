import AppKit

/// Finding the applications that open a file and the one the editor preference names.
extension MacIntegrationPlugin {
    /// The applications that open a file, the default one first.
    ///
    /// Launch Services looks at the file to know its type: not for the main thread.
    nonisolated internal static func installedApplications(for url: URL) -> [URL] {
        let workspace = NSWorkspace.shared
        var all = workspace.urlsForApplications(toOpen: url)
        if let preferred = workspace.urlForApplication(toOpen: url) {
            all.removeAll { $0 == preferred }
            all.insert(preferred, at: 0)
        }
        return all
    }

    /// Finds the application the editor preference names: by path, by name in the application
    /// folders, or by bundle identifier; TextEdit when none is found.
    ///
    /// Looks at the disk: not for the main thread.
    nonisolated internal static func editorApplication(named setting: String) -> URL {
        let fallback = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let text = setting.trimmingCharacters(in: .whitespaces)
        let files = FileManager.default
        if text.hasPrefix("/") || text.hasPrefix("~") {
            let path = expandingTilde(in: text)
            return files.fileExists(atPath: path) ? URL(fileURLWithPath: path) : fallback
        }
        let bareName = text.hasSuffix(".app") ? String(text.dropLast(4)) : text
        guard !bareName.isEmpty else {
            return fallback
        }
        let folders = [
            "/Applications", "/System/Applications", "/Applications/Utilities", "/System/Applications/Utilities",
            files.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        ]
        if let path = folders.map({ $0 + "/" + bareName + ".app" }).first(where: files.fileExists(atPath:)) {
            return URL(fileURLWithPath: path)
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: text) ?? fallback
    }

    /// `path` with a leading `~` (the user's home folder) or `~name` (that user's) written out, as
    /// the shell does; unchanged without one, or when there is no such user.
    nonisolated internal static func expandingTilde(in path: String) -> String {
        guard path.hasPrefix("~") else {
            return path
        }
        let rest = path.dropFirst()
        let user = rest.prefix { $0 != "/" }
        let files = FileManager.default
        guard let home = user.isEmpty ? files.homeDirectoryForCurrentUser : files.homeDirectory(forUser: String(user))
        else {
            return path
        }
        return home.path + rest.dropFirst(user.count)
    }
}
