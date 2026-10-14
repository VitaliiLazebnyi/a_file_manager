public import Foundation

/// The file systems the plugins provide, found by URL scheme. Filled while the plugins start
/// and read from any thread. Unchecked: `providers` is guarded by `lock` (a plugin that starts
/// may already have work in the background while a later one registers), and the lists of
/// flushers, releasers and closers by `flushLock`.
public final class FileSystemRegistry: @unchecked Sendable {
    private let lock = NSLock()
    /// Guards the flushers, releasers and closers: they are added while the plugins start and
    /// called from the threads of jobs.
    private let flushLock = NSLock()
    private var providers: [any FileSystemProvider] = []
    private var flushers: [@Sendable (URL, CancellationFlag) throws -> Void] = []
    private var releasers: [@MainActor (URL) -> Void] = []
    private var closers: [@Sendable (URL, CancellationFlag) -> Void] = []

    public init() {}

    public func register(_ provider: any FileSystemProvider) {
        lock.lock()
        defer { lock.unlock() }
        precondition(
            !providers.contains { $0.scheme == provider.scheme },
            "A file system for \(provider.scheme): is registered twice"
        )
        providers.append(provider)
    }

    /// Every provider, in registration order.
    public var all: [any FileSystemProvider] { lock.withLock { providers } }

    public func provider(for url: URL) throws -> any FileSystemProvider {
        let scheme = url.scheme ?? "file"
        guard let provider = lock.withLock({ providers.first(where: { $0.scheme == scheme }) }) else {
            throw FileSystemError.noProvider(url)
        }
        return provider
    }

    /// What can be done at a location; nothing where no file system answers for it. Answers
    /// at once, on any thread.
    public func capabilities(for url: URL) -> FileSystemCapabilities {
        (try? provider(for: url))?.capabilities(for: url) ?? []
    }

    /// Posted on the main thread when a file system has learned that what `volume(of:)` says
    /// about a volume (its free space, say) is no longer what it last answered. The object is
    /// the file system (a `FileSystemProvider`), and `userInfo` holds the volume's root under
    /// `volumeRootKey`, when the file system knows it: whoever
    /// shows a `VolumeInfo` of a place at or below it asks `volume(of:)` again, in the
    /// background, and hands the answer to `PanelModel.setVolume`.
    public static let volumeInfoDidChange = Notification.Name("AFMVolumeInfoDidChange")
    public static let volumeRootKey = "volumeRoot"

    /// The real location behind a location, followed to the end: what
    /// `FileSystemProvider.realLocation(of:)` answers, asked again of the file system of the
    /// answer, until one says the location is itself. Works on the URLs alone.
    public func realLocation(of url: URL) -> URL {
        var current = url
        // No honest chain is long; a circle among file systems ends here.
        for _ in 0..<16 {
            guard let next = (try? provider(for: current))?.realLocation(of: current), !next.isSameLocation(as: current)
            else { break }
            current = next
        }
        return current
    }

    /// Registers work that makes a file up to date before somebody else uses it: a plugin
    /// that keeps changes to a file back for a while (an archive that is written after a
    /// delay) writes them when asked. `flush` is called on background threads with the
    /// location of a file that is about to be read, moved or deleted; it returns at once for
    /// a file it has nothing to do with, blocks for as long as the writing takes otherwise,
    /// and throws when the file could not be brought up to date.
    public func addFlusher(_ flush: @escaping @Sendable (URL, CancellationFlag) throws -> Void) {
        flushLock.lock()
        flushers.append(flush)
        flushLock.unlock()
    }

    /// Has every registered flusher bring the file at `url` up to date. **Who calls it:**
    /// whoever is about to read, copy, move, upload or delete a file that some plugin may
    /// still have changes for, on its own background thread, before the first read. A throw
    /// means the file on disk is not what the user sees: the operation is not carried out.
    public func flushPendingWrites(to url: URL, cancellation: CancellationFlag) throws {
        flushLock.lock()
        let flushers = self.flushers
        flushLock.unlock()
        for flush in flushers { try flush(url, cancellation) }
    }

    // MARK: Letting go of a volume

    /// Registers who keeps something open on volumes and lets go of it before one is ejected:
    /// closes the windows that show its files, stops what reads there. Called on the main
    /// thread with the volume's location; whoever registers is the plugin that holds it.
    public func addVolumeReleaser(_ release: @escaping @MainActor (URL) -> Void) {
        flushLock.lock()
        releasers.append(release)
        flushLock.unlock()
    }

    /// The same for what has to wait on the disk to let go (writing what is pending, closing
    /// files): called on the thread of the job that ejects, after the releasers.
    public func addVolumeCloser(_ close: @escaping @Sendable (URL, CancellationFlag) -> Void) {
        flushLock.lock()
        closers.append(close)
        flushLock.unlock()
    }

    /// Main thread: every releaser lets go of what it shows or reads on `volume`.
    @MainActor public func releaseVolume(_ volume: URL) {
        flushLock.lock()
        let releasers = self.releasers
        flushLock.unlock()
        for release in releasers { release(volume) }
    }

    /// Job thread: what is pending for `volume` is written (`flushPendingWrites`), then every
    /// closer closes what it keeps open there. A failed write is thrown, and nothing is closed:
    /// a volume that is ejected then would lose it.
    public func closeFiles(on volume: URL, cancellation: CancellationFlag) throws {
        try flushPendingWrites(to: volume, cancellation: cancellation)
        flushLock.lock()
        let closers = self.closers
        flushLock.unlock()
        for close in closers { close(volume, cancellation) }
    }

    /// Blocks like the provider's own `item(at:)`; not for the main thread.
    public func item(at url: URL) -> FileItem? {
        (try? provider(for: url))?.item(at: url)
    }

    /// How a location is written for the user: each file system decides for its own.
    public func displayPath(_ url: URL) -> String {
        (try? provider(for: url))?.displayPath(url) ?? url.absoluteString
    }

    /// Reads a location typed by the user. A relative path belongs to the file system of
    /// `base` and `~` is the home folder. A path from the root (`/Users/me`) is one of the
    /// local disks, which is how their locations are written for the user, unless the file
    /// system of `base` reads such paths itself (`readsRootedPaths`). Works on the text alone.
    public func location(from text: String, relativeTo base: URL) -> URL {
        let text = text.trimmingCharacters(in: .whitespaces)
        // A location written out in full, in the notation of one of the file systems.
        if let url = all.lazy.compactMap({ $0.location(from: text) }).first {
            return url.standardized
        }
        if text == "~" || text.hasPrefix("~/") {
            return URL(fileURLWithPath: NSString(string: text).expandingTildeInPath, isDirectory: false).standardized
        }
        if text.hasPrefix("/") {
            let baseReadsIt = (try? provider(for: base))?.readsRootedPaths ?? true
            if !baseReadsIt, all.contains(where: { $0.scheme == "file" }) {
                return URL(fileURLWithPath: text, isDirectory: false).standardized
            }
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
            components.path = text
            return (components.url ?? URL(fileURLWithPath: text, isDirectory: false)).standardized
        }
        return text.isEmpty ? base : base.appending(name: text).standardized
    }
}
