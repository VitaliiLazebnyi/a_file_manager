public import AFMKernel
import AppKit
public import Foundation

/// The file system of the Mac itself (`file:` URLs).
///
/// The system calls it uses are safe to make from several threads at once; the little it remembers
/// (the list of places, what it learned about volumes and kinds of folders, the locked copies it
/// made) is guarded by locks.
///
/// Unchecked: every table is guarded by the lock named beside it (`packageLock`,
/// `lockedLock`, `placesLock`, `volumeLock`, `spareLock`); `mountObservers` is set in `init`
/// and read in `deinit`; the default file manager may be used from any thread.
public final class LocalFileSystem: FileSystemProvider, @unchecked Sendable {
    /// Posted on the main thread when the list of places was read again and is not what
    /// `places()` last answered.
    ///
    /// The object is the file system.
    public static let placesDidChange = Notification.Name("AFMPlacesDidChange")

    /// The scheme of the locations this file system serves: `file`.
    public let scheme = "file"
    /// What can be done here besides reading: writing, moving to the Trash, continuing a file.
    public let capabilities: FileSystemCapabilities = [.write, .trash, .append]
    /// The system's file manager, for the few things done through it (the Trash, listing a volume
    /// without bulk reads, finding the folder a location will be made in).
    internal let fileManager = FileManager.default
    /// Nil everywhere unless a test stands in for the system (`LocalProbes`).
    internal let probes: LocalProbes

    /// Guards `packageExtensions`.
    internal let packageLock = NSLock()
    /// Lowercase extension → whether folders with it are packages, and when that was learned.
    ///
    /// Guarded by `packageLock`.
    internal var packageExtensions: [String: (isPackage: Bool, learned: UInt64)] = [:]
    /// Guards `lockedCopies`.
    internal let lockedLock = NSLock()
    /// Path → file of the locked copies `copy` has made under a temporary name and nobody has
    /// renamed or removed yet, and when.
    ///
    /// These are the only ones this file system takes the lock off for the moment of a rename or
    /// removal: the caller is about to give them their real names. A copy that kept its name is the
    /// user's file like the one it was copied from, and stays as locked as that. Guarded by
    /// `lockedLock`.
    internal var lockedCopies: [String: LockedCopy] = [:]

    private var mountObservers: [any NSObjectProtocol] = []
    /// Guards the state of the places, from `knownPlaces` to `abandonedReads`.
    internal let placesLock = NSLock()
    /// The places `places()` answers with: the last list that was read, or the fixed places.
    internal var knownPlaces: [Place]
    /// When the places were last read (0: not yet).
    internal var placesRead: UInt64 = 0
    /// A reading of the places is under way.
    internal var isReadingPlaces = false
    /// The places have to be read once more after the reading under way.
    internal var placesChangedMeanwhile = false
    /// Which reading is the current one: a reading that has taken too long (a mount that does
    /// not answer) is given up, and whatever it finds later is not used.
    ///
    /// The reading goes on in its thread until the system lets it go; no new one is started while
    /// two are stuck.
    internal var placesGeneration = 0
    /// Readings that were given up and are still stuck in their threads.
    internal var abandonedReads = 0

    /// Readings of the places that were given up and have not come back.
    internal var abandonedReadings: Int { placesLock.withLock { abandonedReads } }

    /// Volumes whose questions have not been answered yet: asked about once, not again and
    /// again, while a share that does not answer holds a thread.
    internal let volumesAsking = Locked(Set<String>())

    /// Guards `volumeQuestions` and `lastVolumes`.
    internal let volumeLock = NSLock()
    /// The question to each mount point that has not come back.
    internal var volumeQuestions: [String: VolumeQuestion] = [:]
    /// The last answer for each mount point.
    internal var lastVolumes: [String: VolumeInfo] = [:]

    /// Guards `spareSpace`.
    internal let spareLock = NSLock()
    /// Mount point → what the system would free on demand there, as last measured.
    ///
    /// Guarded by `spareLock`.
    internal var spareSpace: [String: SpareMeasurement] = [:]

    /// The file system of this Mac, as the program uses it.
    public convenience init() {
        self.init(probes: LocalProbes())
    }

    /// Tests stand in for the system with `probes`.
    internal init(probes: LocalProbes) {
        self.probes = probes
        knownPlaces = Self.fixedPlaces(home: probes.home ?? FileManager.default.homeDirectoryForCurrentUser)
        // Disks that come and go change the list of places; it is read again behind the scenes.
        let workspace = NSWorkspace.shared.notificationCenter
        let names = [
            NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ]
        mountObservers = names.map { name in
            workspace.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.refreshPlaces() }
        }
        _ = Self.defaultFileMode
        refreshPlaces()
    }

    /// An error of the system (`errno` `code`) about the item at `url`, with the path in its text.
    internal static func posixError(_ code: Int32, _ url: URL) -> any Error {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code)) + ": " + url.path]
        )
    }

    /// The folder above an absolute path, by its text alone: `/a/b` and `/a/b/` give `/a`, `/a`
    /// gives `/`, and `/` stays `/`; a bare name gives the empty path.
    internal static func parentPath(of path: String) -> String {
        var bytes = Array(path.utf8)
        // Slashes at the end name no folder of their own.
        while bytes.count > 1, bytes.last == 0x2F { bytes.removeLast() }
        switch bytes.lastIndex(of: 0x2F) {
        case nil:
            return ""

        case 0:
            return "/"

        case let slash?:
            return String(Substring(path.utf8.prefix(slash)))
        }
    }

    /// The location as the user reads it: its path.
    public func displayPath(_ url: URL) -> String {
        url.path
    }

    /// The folder above `directory`; nil for `/`.
    public func parent(of directory: URL) -> URL? {
        directory.path == "/" ? nil : directory.deletingLastPathComponent()
    }

    /// Every local location is below `/`: no need to go up to find that out.
    public func root(of _: URL) -> URL {
        URL(fileURLWithPath: "/", isDirectory: true)
    }

    /// The stream of changes runs on queues of its own; `onChange` is called on the main
    /// thread, and only for the directories that were asked for.
    ///
    /// Returns at once: the folders are resolved and the stream is made in the background (a share
    /// that does not answer must not hold up the caller).
    @preconcurrency
    public func watch(_ directories: [URL], onChange: @escaping @MainActor @Sendable ([URL]) -> Void) -> (
        any WatchToken
    )? {
        // The watcher delivers on the main queue.
        let watcher = DirectoryWatcher { changed in MainActor.assumeIsolated { onChange(changed) } }
        watcher.watch(directories)
        return watcher
    }

    deinit {
        mountObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }
}
