public import AFMKernel
public import Foundation
import os

/// Settings kept in the macOS preferences.
///
/// A value that may be large (`setLarge`: a long history, megabytes of it) is not kept there:
/// the preferences are one file that is read whole at the start and written whole after every
/// change. Each such value has a file of its own in `largeFolder`, written on a background
/// thread, newest value last, however often it is set; what is read comes from memory once it
/// was read or set. Safe to use from any thread: the large values are guarded by `lock`, and
/// `UserDefaults` is thread-safe.
public final class UserDefaultsSettings: SettingsStore, @unchecked Sendable {
    /// Where a large value that cannot be written is reported.
    private static let log = Log.logger("Shell")

    /// Where the large values are kept; nil keeps them with the rest.
    public let largeFolder: URL?
    /// The preferences.
    private let defaults: UserDefaults
    /// Guards `large`, `unwritten` and `isWriting`, and wakes whoever waits for the writes.
    private let lock = NSCondition()
    /// The large values that were read or set, by key; `.some(nil)` for one that is not there.
    private var large: [String: Data?] = [:]
    /// The keys whose files are behind what `large` says.
    private var unwritten: Set<String> = []
    /// True while a background thread writes the large values.
    private var isWriting = false

    /// Settings in `defaults`, with their large values in `largeFolder`.
    ///
    /// The standard preferences keep their large values in the program's folder in Application
    /// Support; any other store keeps them with the rest unless it is given a folder.
    public init(defaults: UserDefaults = .standard, largeFolder: URL? = nil) {
        self.defaults = defaults
        self.largeFolder =
            largeFolder ?? (defaults === UserDefaults.standard ? Self.standardLargeFolder(of: .main) : nil)
    }

    /// The folder for the large values of the standard preferences of the program in `bundle`.
    ///
    /// The program's folder in Application Support, named by its bundle identifier (by the
    /// process's name when it has none); nil when the system names no such folder.
    internal static func standardLargeFolder(of bundle: Bundle) -> URL? {
        let name = bundle.bundleIdentifier ?? ProcessInfo.processInfo.processName
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("Settings", isDirectory: true)
    }

    /// The value stored under `key` in the preferences; any thread.
    public func data(forKey key: String) -> Data? { defaults.data(forKey: key) }

    /// Stores `data` under `key` in the preferences, or removes it for nil; any thread.
    public func set(_ data: Data?, forKey key: String) { defaults.set(data, forKey: key) }

    /// The file of a key.
    ///
    /// Its name is written with letters, digits and `-._` alone, everything else as `%XX` of
    /// its bytes, so no key can name a file outside the folder. Nil without a folder.
    internal func largeFile(forKey key: String) -> URL? {
        guard let largeFolder else {
            return nil
        }
        var name = ""
        for byte in key.utf8 {
            let isPlain =
                (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || byte == 0x2D || byte == 0x5F
                || (byte == 0x2E && !name.isEmpty)
            name += isPlain ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }
        return largeFolder.appendingPathComponent(String(name.prefix(200)) + ".data", isDirectory: false)
    }

    /// A value that may be large: from memory once it was read or set, otherwise from its file.
    ///
    /// A value that was stored with the rest before is still found there. Any thread.
    public func largeData(forKey key: String) -> Data? {
        guard let file = largeFile(forKey: key) else {
            return data(forKey: key)
        }
        if let known = lock.withLock({ large[key] }) {
            return known
        }
        // Read outside the lock.
        let read = (try? Data(contentsOf: file)) ?? defaults.data(forKey: key)
        return lock.withLock {
            // Set meanwhile: that is the value.
            let value = large[key] ?? read
            large[key] = .some(value)
            return value
        }
    }

    /// Keeps a value that may be large: in memory at once, in its file soon.
    ///
    /// One background thread writes the files, newest value last. Any thread.
    public func setLarge(_ data: Data?, forKey key: String) {
        guard largeFile(forKey: key) != nil else {
            set(data, forKey: key)
            return
        }
        let starts = lock.withLock {
            large[key] = .some(data)
            unwritten.insert(key)
            let starts = !isWriting
            isWriting = true
            return starts
        }
        // One writer at a time, on a thread that may wait for the disk as long as it has to.
        if starts {
            BlockingCalls.run { [self] in writeLargeValues() }
        }
    }

    /// Waits until every large value that was set is in its file, for at most `timeout` seconds.
    ///
    /// For when the program quits. Returns false when the time ran out.
    @discardableResult
    public func waitForWrites(atMost timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        lock.lock()
        defer { lock.unlock() }
        while isWriting, lock.wait(until: deadline) {
            // Woken by the writer when it is done: look again. A wait that ran out of time ends it.
        }
        return !isWriting
    }

    /// Writes the large values that are behind, one by one, until none is; on the writer's
    /// thread.
    private func writeLargeValues() {
        while let (key, value) = nextUnwritten() {
            if let file = largeFile(forKey: key) {
                write(value, to: file)
                // The copy that was kept with the rest before is not needed any more.
                if defaults.object(forKey: key) != nil {
                    defaults.removeObject(forKey: key)
                }
            }
        }
    }

    /// The next key whose file is behind, with its value; nil ends the writing and wakes whoever
    /// waits for it.
    private func nextUnwritten() -> (key: String, value: Data?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let key = unwritten.first else {
            isWriting = false
            lock.broadcast()
            return nil
        }
        unwritten.remove(key)
        return (key, large[key].flatMap(\.self))
    }

    /// Writes `value` into `file`, readable by the user alone, or removes the file for nil.
    ///
    /// A file that cannot be written is reported in the log; the value stays in memory for
    /// this run.
    private func write(_ value: Data?, to file: URL) {
        let manager = FileManager.default
        do {
            guard let value else {
                if manager.fileExists(atPath: file.path) {
                    try manager.removeItem(at: file)
                }
                return
            }
            try manager.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try value.write(to: file, options: .atomic)
            // A history may hold what nobody else should read.
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            let reason = error.localizedDescription
            Self.log.error(
                "A large setting was not written to \(file.path, privacy: .private): \(reason, privacy: .private)"
            )
        }
    }

    deinit {
        // Nothing to release: the writer holds the store while it writes.
    }
}
