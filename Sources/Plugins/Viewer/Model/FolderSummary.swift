import AFMContracts
import AFMKernel
import Foundation

/// What a folder holds, for the quick-view pane (spec 03 › Quick View: "on a folder,
/// information about its occupied space").
struct FolderSummary: Equatable {
    var files = 0
    var folders = 0
    var bytes: Int64 = 0
    /// Counting stopped at its limit: the numbers are a part of the whole.
    var isPartial = false

    var text: String {
        (isPartial ? "At least " : "")
            + "\(Format.bytes(Int64(files))) file\(files == 1 ? "" : "s"), \(Format.bytes(Int64(folders))) folder\(folders == 1 ? "" : "s"), "
            + "\(Format.bytes(bytes)) bytes (\(Format.shortSize(bytes)))"
    }

    static func + (left: Self, right: Self) -> Self {
        Self(
            files: left.files + right.files,
            folders: left.folders + right.folders,
            bytes: left.bytes.addingSaturated(right.bytes),
            isPartial: left.isPartial || right.isPartial
        )
    }

    /// Counts everything below `directory` through its file system.
    ///
    /// The subfolders are walked on all cores at once. Blocks; call it on a background thread.
    /// Returns what was counted up to then when `cancellation` is set (the listings are
    /// cancellable, so a server that does not answer does not keep the threads). Links are counted,
    /// not followed. With `limit`, counting stops after that many entries, as it does for a tree on
    /// a server, where every folder is a trip; `isPartial` is then set.
    static func measure(
        _ directory: URL,
        provider: any FileSystemProvider,
        cancellation: CancellationFlag,
        limit: Int? = nil
    ) -> Self {
        let budget = limit.map { Budget($0) }
        var result = measure(directory, provider: provider, cancellation: cancellation, budget: budget)
        result.isPartial = budget?.exhausted == true
        return result
    }

    /// The entries still to be counted, shared by all the threads of a walk.
    ///
    /// All state is guarded by `lock`.
    private final class Budget: @unchecked Sendable {
        private let lock = NSLock()
        private var left: Int
        private var isExhausted = false

        init(_ limit: Int) { left = max(0, limit) }

        /// Takes `count` entries; false when there is no room for them all (the walk then ends).
        func take(_ count: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard left >= count else {
                isExhausted = true
                left = 0
                return false
            }
            left -= count
            return true
        }

        var exhausted: Bool {
            lock.lock()
            defer { lock.unlock() }
            return isExhausted
        }
    }

    private static func measure(
        _ directory: URL,
        provider: any FileSystemProvider,
        cancellation: CancellationFlag,
        budget: Budget?
    ) -> Self {
        guard !cancellation.isCancelled, budget?.exhausted != true,
            let items = try? provider.list(directory, showHidden: true, cancellation: cancellation),
            !cancellation.isCancelled
        else { return Self() }
        if let budget, !budget.take(items.count) { return Self() }
        var summary = Self()
        for item in items {
            if item.isRealDirectory {
                summary.folders += 1
            } else {
                summary.files += 1
                summary.bytes = summary.bytes.addingSaturated(item.size)
            }
        }
        let below = Parallel.map(items.filter(\.isRealDirectory)) {
            measure($0.url, provider: provider, cancellation: cancellation, budget: budget)
        }
        return below.reduce(summary, +)
    }
}
