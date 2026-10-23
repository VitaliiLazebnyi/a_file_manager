import AFMKernel
import AppKit

/// Reads a long list of files that another program put on the pasteboard without holding up
/// the main thread: the pasteboard may only be read there, and every file is a question to
/// the system (see `ClipboardPlugin`).
///
/// The items are asked a few milliseconds' worth per turn of the main run loop.
///
/// **Threading.** `run` is called on a job's thread and waits there; the reading happens on
/// the main thread in slices it schedules. Called on the main thread itself (a job service
/// that runs its work at once) it reads everything in one go, as there is nobody to wait for.
/// The counters the two threads share are behind `lock`.
///
/// Unchecked: the counters are guarded by `lock`; the items and the pasteboard are only
/// touched on the main thread.
internal final class FileListReading: @unchecked Sendable {
    /// What a reading came to.
    internal enum Outcome: Equatable {
        /// Cancelled, or the pasteboard got other contents while it was read.
        case abandoned
        /// The files the items stand for, in their order.
        case read([URL])
    }

    /// How long one slice may take before the main thread gets its turn again.
    internal static let sliceTime: UInt64 = 6_000_000

    private let items: [NSPasteboardItem]
    private let pasteboard: NSPasteboard
    private let changeCount: Int
    private let lock = NSLock()
    private var next = 0
    private var urls: [URL] = []
    /// What the reading came to; set before `finished` is signalled.
    private var outcome = Outcome.abandoned
    private let finished = DispatchSemaphore(value: 0)
    private var sliceCount = 0
    /// How many slices the reading took; for tests.
    internal var slices: Int { lock.withLock { sliceCount } }

    /// Main thread: the pasteboard's state is noted here.
    internal init(_ items: [NSPasteboardItem], on pasteboard: NSPasteboard) {
        self.items = items
        self.pasteboard = pasteboard
        changeCount = pasteboard.changeCount
    }

    /// The file an item stands for, if it is one.
    internal static func fileURL(of item: NSPasteboardItem) -> URL? {
        guard let text = item.string(forType: .fileURL), let url = URL(string: text), url.isFileURL else {
            return nil
        }
        // A reference to a file by its number instead of its path is turned into the path (newer
        // systems give the path when it is asked for, older ones the number).
        if text.hasPrefix("file:///.file/") {
            return (url as URL._ObjectiveCType).filePathURL
        }
        return url
    }

    /// Blocks until the list is read. `progress` (done, total) is called on the calling
    /// thread about ten times a second while it waits.
    internal func run(cancellation: CancellationFlag, progress: (Int, Int) -> Void) -> Outcome {
        if Thread.isMainThread {
            step(cancellation, sliced: false)
        } else {
            DispatchQueue.main.async { self.step(cancellation, sliced: true) }
            while finished.wait(timeout: .now() + 0.1) == .timedOut {
                progress(lock.withLock { next }, items.count)
            }
        }
        return lock.withLock { outcome }
    }

    /// One slice.
    ///
    /// Main thread.
    private func step(_ cancellation: CancellationFlag, sliced: Bool) {
        guard !cancellation.isCancelled, pasteboard.changeCount == changeCount else {
            finish(.abandoned)
            return
        }
        let start = DispatchTime.now().uptimeNanoseconds
        var (index, found): (Int, [URL]) = (lock.withLock { next }, [])
        repeat {
            guard index < items.count else { break }
            if let url = Self.fileURL(of: items[index]) { found.append(url) }
            index += 1
        } while !sliced || DispatchTime.now().uptimeNanoseconds - start < Self.sliceTime
        let isDone = index >= items.count
        lock.withLock {
            next = index
            urls += found
            sliceCount += 1
        }
        // Both ways are rare against the loop above, so each is a case of its own.
        switch isDone {
        case false:
            DispatchQueue.main.async { self.step(cancellation, sliced: sliced) }

        case true:
            // Changed while the last slice was read: what was read may be half of each.
            finish(pasteboard.changeCount == changeCount ? .read(lock.withLock { urls }) : .abandoned)
        }
    }

    private func finish(_ result: Outcome) {
        lock.withLock { outcome = result }
        finished.signal()
    }

    deinit {
        // Nothing to release.
    }
}
