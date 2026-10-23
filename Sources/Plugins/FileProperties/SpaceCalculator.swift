import AFMContracts
import AFMKernel
import Foundation

/// Measures files and whole trees through their file-system providers.
///
/// **Threading.** `measure` blocks and is meant for a job's thread. The subfolders of every
/// folder are measured on all cores at once (`Parallel.map`); each branch adds up its own
/// figures and hands them back, so nothing is shared between the threads but the cancellation
/// flag and the progress meter, which protect themselves.
internal struct SpaceCalculator {
    /// The providers that list the folders and describe the files.
    internal let fileSystems: FileSystemRegistry
    /// Stops the measuring; what was measured until then is what comes back.
    internal var cancellation = CancellationFlag()
    /// The allocation unit of the volume a copy would go to; nil rounds nothing.
    internal var targetCluster: Int64?
    /// Told how many items were counted, folder by folder; nil reports nothing.
    internal var meter: ProgressMeter?
    /// Whether the space really taken on the disk is asked for, which costs one more call per
    /// file; "Calculate all folder sizes" shows sizes only.
    internal var measuresAllocated = true

    /// `size` rounded up to a whole number of `cluster`s; a cluster of nil, 0 or 1 leaves it as it is.
    internal static func round(_ size: Int64, to cluster: Int64?) -> Int64 {
        guard let cluster, cluster > 1 else {
            return size
        }
        return size.addingSaturated(cluster - 1) / cluster * cluster
    }

    /// One figure per item, in the same order.
    ///
    /// A folder counts itself and everything below.
    internal func measure(_ items: [FileItem]) -> [SpaceTotals] {
        Parallel.map(items) { item in
            item.isRealDirectory ? measure(directory: item.url) + SpaceTotals(folders: 1) : measure(file: item)
        }
    }

    private func measure(file item: FileItem) -> SpaceTotals {
        // Only the Mac's own file system says how much room a file really takes.
        let allocated =
            measuresAllocated && item.url.isFileURL ? LocalInfo.details(item.url)?.allocated ?? item.size : item.size
        return SpaceTotals(
            bytes: item.size,
            allocated: allocated,
            rounded: Self.round(item.size, to: targetCluster),
            files: 1
        )
    }

    /// Everything below a directory, not counting the directory itself.
    ///
    /// Links are counted as the links they are and never followed.
    internal func measure(directory: URL) -> SpaceTotals {
        guard !cancellation.isCancelled else {
            return SpaceTotals()
        }
        // Listed with the flag: a folder on a server that has stopped answering ends when the
        // job is cancelled, and does not keep a thread of the pool.
        guard
            let items = try? fileSystems.provider(for: directory)
                .list(
                    directory,
                    showHidden: true,
                    cancellation: cancellation
                )
        else {
            return cancellation.isCancelled ? SpaceTotals() : SpaceTotals(unreadable: 1)
        }
        // A listing that ended because of the cancel is not the whole folder.
        guard !cancellation.isCancelled else {
            return SpaceTotals()
        }
        var totals = SpaceTotals()
        var folders: [URL] = []
        for item in items {
            if item.isRealDirectory {
                folders.append(item.url)
            } else {
                totals += measure(file: item)
            }
        }
        totals.folders += folders.count
        meter?.add(items.count, at: fileSystems.displayPath(directory))
        return Parallel.map(folders) { measure(directory: $0) }.reduce(totals, +)
    }
}
