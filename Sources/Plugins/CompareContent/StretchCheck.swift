import AFMKernel
import Foundation
import os

/// One check of two local files for being identical, stretch by stretch, on several threads at once.
///
/// Every worker has its own two readers and moves them to the stretches it takes; the workers share, behind
/// a lock, the next stretch to take and what was found.
internal struct StretchCheck: Sendable {
    /// What the workers share.
    internal struct Progress {
        /// The next stretch to take.
        internal var next = 0
        /// Whether a stretch was found to differ; the workers then stop.
        internal var differs = false
        /// The first failure of a worker; the workers then stop.
        internal var failure: (any Error)?
    }

    /// The two files, each with its file system.
    internal let files: [(system: any FileSystemProvider, url: URL)]
    /// The size of each of the two files.
    internal let size: Int64
    /// How many bytes one worker compares at a time.
    internal let stretch: Int
    /// Set by the user; the workers stop and the check throws `CancellationError`.
    internal let cancellation: CancellationFlag
    /// What the workers share, behind its lock.
    private let progress = OSAllocatedUnfairLock(initialState: Progress())

    /// How many stretches the files have.
    internal var count: Int {
        // (A size is what a file system says; a server may say anything.)
        Int(max(0, size).addingSaturated(Int64(stretch) - 1) / Int64(stretch))
    }

    /// A check of `files` of `size` bytes, `stretch` bytes at a time.
    internal init(
        files: [(system: any FileSystemProvider, url: URL)],
        size: Int64,
        stretch: Int,
        cancellation: CancellationFlag
    ) {
        self.files = files
        self.size = size
        self.stretch = stretch
        self.cancellation = cancellation
    }

    /// Whether the two files have the same content; throws the first failure of a worker, or
    /// `CancellationError` when cancelled.
    ///
    /// Blocks until every worker is done.
    internal func run() throws -> Bool {
        let stretches = count
        // On the shared pool of `Parallel`, which starts more threads for workers that wait on a disk that does
        // not answer; `concurrentPerform` would have its few threads stuck there.
        _ = Parallel.map(Array(0..<min(stretches, ProcessInfo.processInfo.activeProcessorCount))) { _ in
            work(count: stretches)
        }
        // A cancelled check has no answer, also when the reads it cut short came back different.
        if cancellation.isCancelled {
            throw CancellationError()
        }
        let found = progress.withLock { state in (state.differs, state.failure) }
        if let failure = found.1 {
            throw failure
        }
        return !found.0
    }

    /// One worker: opens its own two readers and compares the stretches it takes until none is left.
    private func work(count: Int) {
        var readers: [any FileReader] = []
        var tokens: [AnyObject] = []
        defer {
            for reader in readers {
                reader.close()
            }
            withExtendedLifetime(tokens) {
                // The readers can be interrupted up to here.
            }
        }
        do {
            for (system, url) in files {
                let reader = try system.read(url, cancellation: cancellation)
                readers.append(reader)
                tokens.append(cancellation.interrupting(reader))
            }
            while let index = take(count: count) {
                let offset = UInt64(index) * UInt64(stretch)
                let length = Int(min(Int64(stretch), size - Int64(offset)))
                try autoreleasepool {
                    for reader in readers {
                        try reader.seek(to: offset)
                    }
                    let blocks = [
                        try CompareLoader.exactly(length, from: readers[0]),
                        try CompareLoader.exactly(length, from: readers[1])
                    ]
                    if blocks[0] != blocks[1] {
                        progress.withLock { state in state.differs = true }
                    }
                }
            }
        } catch {
            progress.withLock { state in state.failure = state.failure ?? error }
        }
    }

    /// The next stretch to compare; nil when all are taken, or the check is decided or cancelled.
    private func take(count: Int) -> Int? {
        progress.withLock { state in
            guard !state.differs, state.failure == nil, state.next < count, !cancellation.isCancelled else {
                return nil
            }
            state.next += 1
            return state.next - 1
        }
    }
}
