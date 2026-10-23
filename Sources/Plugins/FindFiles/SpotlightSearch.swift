import AFMKernel
import Foundation

/// One question to Spotlight.
///
/// The question is started on the main thread; the system then gathers the answer on its own and
/// delivers it on a queue of ours, where the paths are read out of the result (a million of them
/// take seconds), and `completion` is called on the main thread with the paths found. Reading and
/// checking the files afterwards is the caller's business and belongs in the background.
///
/// `completion` and `isStopped` are guarded by `lock`. The metadata query is set up in `init`
/// and started on the main thread; after that only `queue` touches it. The search hears of the end of the
/// gathering for as long as it lives (the system lets go of the observation when it is freed): a
/// notification after the end finds nobody waiting.
internal final class SpotlightSearch: NSObject, SpotlightQuestion, @unchecked Sendable {
    /// The most paths read out of one answer.
    internal static let resultLimit = 1_000_000

    private let metadataQuery = NSMetadataQuery()
    private let queue: OperationQueue
    private let lock = NSLock()
    private var completion: (@MainActor @Sendable ([String], Bool) -> Void)?
    private var isStopped = false

    /// The most paths read out of this answer.
    internal let limit: Int

    private var stopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isStopped
    }

    /// A question that reads at most `limit` paths, in the folders `scopes`.
    ///
    /// `string` is a question in Spotlight's language, as `SpotlightQuery.string` makes it (the
    /// system stops the program at one it cannot read). The answer is read on `queue` (tests hold it, to
    /// choose what comes first).
    internal init(
        _ string: String,
        scopes: [URL],
        limit: Int,
        queue: OperationQueue
    ) {
        let predicate = NSPredicate(fromMetadataQueryString: string)
        self.queue = queue
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        metadataQuery.predicate = predicate
        metadataQuery.searchScopes = scopes
        // The answer is delivered, and read, on this queue and not on the main run loop.
        metadataQuery.operationQueue = queue
        self.limit = limit
        super.init()
    }

    /// `completion` gets the paths and whether the answer was cut at `resultLimit`.
    ///
    /// A question that was stopped is not started again.
    internal func start(completion: @escaping @MainActor @Sendable ([String], Bool) -> Void) {
        lock.lock()
        self.completion = completion
        lock.unlock()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(finished),
            name: .NSMetadataQueryDidFinishGathering,
            object: metadataQuery
        )
        if !metadataQuery.start() {
            queue.addOperation { [weak self] in self?.finished() }
        }
    }

    /// Ends the question without an answer.
    ///
    /// May be called from the main thread while the paths are being read: the reading notices at
    /// its next piece.
    internal func stop() {
        lock.lock()
        isStopped = true
        completion = nil
        lock.unlock()
        // On the queue the answer is read on, after any reading in progress.
        // Handed to `queue`, the only one that touches the query once it has started.
        let query = Handover(metadataQuery)
        queue.addOperation { query.value.stop() }
    }

    /// Reads the paths out of the answer and hands them on; runs on `queue`.
    @objc
    private func finished() {
        metadataQuery.disableUpdates()
        var paths: [String] = []
        let total = metadataQuery.resultCount
        let count = min(total, limit)
        paths.reserveCapacity(count)
        var index = 0
        while index < count, !stopped {
            // The attribute values are autoreleased objects: a piece at a time.
            autoreleasepool {
                for item in index..<min(index + 5_000, count) {
                    if let path = (metadataQuery.result(at: item) as? NSMetadataItem)?
                        .value(
                            forAttribute: NSMetadataItemPathKey
                        ) as? String
                    {
                        paths.append(path)
                    }
                }
            }
            index += 5_000
        }
        lock.lock()
        // Nil once stopped (`stop` lets go of it) or told already.
        let waiting = completion
        completion = nil
        isStopped = true
        lock.unlock()
        metadataQuery.stop()
        guard let waiting else {
            return
        }
        DispatchQueue.main.async { [paths] in waiting(paths, total > count) }
    }
}
