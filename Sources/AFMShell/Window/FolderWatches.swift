import AFMKernel
import Foundation

/// The folders the panels show, each watched by its file system for changes made by other programs.
///
/// Setting a watch up asks the file system about the folder (the local one resolves its real
/// path), which on a share that has stopped answering takes as long as the share pleases. So
/// it is done in the folder's lane (`Background`), never on the main thread; the main thread
/// only notes what is wanted and takes the watch over when it is there, if it is still wanted
/// then. Main thread only.
@MainActor
internal final class FolderWatches {
    /// When setting a watch up took longer than this, the folder is read once more: what
    /// changed meanwhile went unseen.
    internal static let slowWatch: TimeInterval = 0.5

    /// The file systems that watch.
    private let fileSystems: FileSystemRegistry
    /// Called with the folders that changed.
    private let onChange: ([URL]) -> Void
    /// The folders that are watched or about to be, by location.
    private var watches: [String: FolderWatch] = [:]
    /// The locations last asked for.
    private var watchedLocations: Set<String> = []
    /// Set when the window goes away: nothing is watched any more.
    private var isShutDown = false

    /// Watches of the folders of `fileSystems`; `onChange` hears of changes, on the main thread.
    internal init(fileSystems: FileSystemRegistry, onChange: @escaping ([URL]) -> Void) {
        self.fileSystems = fileSystems
        self.onChange = onChange
    }

    /// Watches exactly the folders of `wanted`, by location.
    ///
    /// A folder that stays wanted keeps its watch; one that is no longer wanted loses it.
    internal func watch(_ wanted: [String: URL]) {
        guard !isShutDown, Set(wanted.keys) != watchedLocations else {
            return
        }
        watchedLocations = Set(wanted.keys)
        for (key, watch) in watches where wanted[key] == nil {
            watch.isWanted = false
            guard !watch.isStarting else {
                continue
            }
            watches[key] = nil
            // Ending a watch is the file system's business too: not on this thread.
            Background.release(&watch.watcher)
        }
        for (key, directory) in wanted {
            if let watch = watches[key] {
                // Still there, or still being set up: taken up again.
                watch.isWanted = true
                continue
            }
            guard let provider = try? fileSystems.provider(for: directory) else {
                continue
            }
            let watch = FolderWatch(directory: directory)
            watches[key] = watch
            start(watch, at: key, with: provider)
        }
    }

    /// Stops watching, for good.
    internal func shutDown() {
        isShutDown = true
        for watch in watches.values {
            watch.isWanted = false
            Background.release(&watch.watcher)
        }
        watches = [:]
        watchedLocations = []
    }

    /// Has `provider` set the watch up in the folder's lane and takes it over when it is there.
    private func start(_ watch: FolderWatch, at key: String, with provider: any FileSystemProvider) {
        let directory = watch.directory
        let began = ProcessInfo.processInfo.systemUptime
        // The background takes nothing along that belongs to the main thread, only two weak
        // references for the file system's callback.
        Background.storage(
            "watch",
            at: directory,
            qos: .utility,
            work: { [weak self, weak watch] () -> (any WatchToken)? in
                provider.watch([directory]) { [weak self, weak watch] changed in
                    // Main thread, as the file system promises.
                    guard let self, let watch, watch.isWanted, watches[key] === watch else {
                        return
                    }
                    onChange(changed)
                }
            },
            then: { [weak self] watcher in
                guard let self else {
                    // The window went away meanwhile.
                    var watcher = watcher
                    Background.release(&watcher)
                    return
                }
                take(watcher, for: watch, at: key, began: began)
            }
        )
    }

    /// The file system has set the watch up (`began` in the system's uptime): kept if it is
    /// still wanted, let go of otherwise.
    private func take(_ watcher: (any WatchToken)?, for watch: FolderWatch, at key: String, began: TimeInterval) {
        var watcher = watcher
        watch.isStarting = false
        guard !isShutDown, watches[key] === watch else {
            Background.release(&watcher)
            return
        }
        guard watch.isWanted else {
            watches[key] = nil
            Background.release(&watcher)
            return
        }
        watch.watcher = watcher
        if ProcessInfo.processInfo.systemUptime - began > Self.slowWatch {
            onChange([watch.directory])
        }
    }

    deinit {
        // Nothing to release: `shutDown` lets go of the watches.
    }
}
