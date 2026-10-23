import Foundation

/// A folder for the plugin's temporary files: archives copied from other file systems, data
/// waiting to be written into an archive.
///
/// It is the user's alone (0700). Emptied when the plugin stops, and in any case when the program
/// exits; what a crash leaves behind is cleared away by the next start (`sweepLeftovers`). Safe to
/// use from any thread.
///
/// Temporary files that have to lie elsewhere (next to an archive on another volume) are
/// noted in a list beside the folder, so that they are found again and removed too.
///
/// Unchecked: what changes, here and in the table of all folders, is guarded by the static
/// `lock`.
internal final class ScratchFolder: @unchecked Sendable {
    private struct Paths {
        var externals: [String]
        var list: String
    }

    /// How the names of the folders begin; what follows is the process number and a unique part.
    internal static let prefix = "afm-archives-"
    private static let keptMark = "kept-unsaved-changes"
    private static let lock = NSLock()
    /// Guarded by `lock`.
    nonisolated(unsafe) private static var folders: [String: ScratchFolder.Paths] = [:]

    /// Registers the clean-up at exit once, for whatever folders exist by then.
    private static let atExit: Void = {
        _ = atexit {
            ScratchFolder.lock.lock()
            let all = ScratchFolder.folders
            ScratchFolder.lock.unlock()
            for (path, paths) in all {
                try? FileManager.default.removeItem(atPath: path)
                for external in paths.externals { ScratchFolder.removeExternal(external) }
                unlink(paths.list)
            }
        }
    }()

    /// Where the folder lies (or will lie: it is made at the first file).
    internal let url: URL
    private var isKept = false
    private var isMade = false
    private var externals: [String] = []

    private var listPath: String { url.path + ".external" }

    /// A folder of a new name of this process's in `parent`; nothing is made on the disk yet.
    internal init(in parent: URL) {
        url = parent.appendingPathComponent(
            "\(Self.prefix)\(getpid())-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    /// The names temporary things get outside the folder; nothing else is ever removed there.
    internal static func isOwnExternalName(_ name: String) -> Bool {
        name.hasPrefix(".")
            && (name.hasSuffix(".afm-zip.tmp") || name.hasSuffix(".afm-pack.tmp") || name.hasPrefix(".afm-spool-"))
    }

    private static func removeExternal(_ path: String) {
        guard isOwnExternalName(URL(fileURLWithPath: path).lastPathComponent) else {
            return
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Removes the folders, and the temporary files noted outside them, of processes that no
    /// longer run: what a crash or a kill left behind.
    ///
    /// Folders that were kept on purpose stay. Touches the disk; meant for a background thread,
    /// once at the start.
    internal static func sweepLeftovers(in parent: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else {
            return
        }
        for name in names where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count)
            guard let pid = pid_t(rest.prefix { $0 != "-" }), pid > 0, pid != getpid() else { continue }
            // Still running (or not ours to ask about): not touched.
            guard kill(pid, 0) != 0, errno == ESRCH else { continue }
            let path = parent.appendingPathComponent(name).path
            if name.hasSuffix(".external") {
                // Only while the folder it belongs to is not one that was kept.
                let folder = String(path.dropLast(".external".count))
                guard !FileManager.default.fileExists(atPath: folder + "/" + keptMark) else { continue }
                let listed = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                for line in listed.split(separator: "\n") { removeExternal(String(line)) }
                unlink(path)
            } else if !FileManager.default.fileExists(atPath: path + "/" + keptMark) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    /// Makes the folder if it is not there.
    ///
    /// Any thread.
    private func prepare() throws {
        _ = Self.atExit
        Self.lock.lock()
        let (made, kept) = (isMade, isKept)
        if !kept { Self.folders[url.path] = Paths(externals: externals, list: listPath) }
        Self.lock.unlock()
        if made, FileManager.default.fileExists(atPath: url.path) {
            return
        }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        Self.lock.lock()
        isMade = true
        Self.lock.unlock()
    }

    /// A new name in the folder ending in `suffix`, made first if it is not there; nothing is created at the name.
    internal func newFile(_ suffix: String) throws -> URL {
        try prepare()
        return url.appendingPathComponent(UUID().uuidString + "." + suffix, isDirectory: false)
    }

    /// Notes a temporary file or folder that lies outside this folder.
    ///
    /// It is removed with the folder if it is still there then, and by the next start if the
    /// program dies before.
    internal func noteExternal(_ url: URL) {
        guard Self.isOwnExternalName(url.lastPathComponent) else {
            return
        }
        try? prepare()
        Self.lock.lock()
        externals.append(url.path)
        if !isKept { Self.folders[self.url.path] = Paths(externals: externals, list: listPath) }
        Self.lock.unlock()
        // One short line appended; a list that cannot be written only means no sweep later.
        let descriptor = open(listPath, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            return
        }
        let line = Array((url.path + "\n").utf8)
        _ = line.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        Darwin.close(descriptor)
    }

    /// Removes the folder and the temporary files noted outside it, unless it was kept.
    internal func removeAll() {
        Self.lock.lock()
        let (stays, outside) = (isKept, externals)
        if !stays {
            externals = []
            Self.folders[url.path] = nil
        }
        Self.lock.unlock()
        guard !stays else {
            return
        }
        try? FileManager.default.removeItem(at: url)
        for path in outside { Self.removeExternal(path) }
        unlink(listPath)
    }

    /// Leaves the folder on the disk, also when the program exits and when a later start
    /// clears away what crashes left: it holds data that could not be written where it belongs.
    internal func keep() {
        Self.lock.lock()
        isKept = true
        Self.folders.removeValue(forKey: url.path)
        Self.lock.unlock()
        unlink(listPath)
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        FileManager.default.createFile(
            atPath: url.appendingPathComponent(Self.keptMark).path,
            contents: Data()
        )
    }

    deinit {
        // Nothing to release.
    }
}
