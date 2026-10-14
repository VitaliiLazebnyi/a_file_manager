import AFMContracts
import AFMKernel
import Foundation

/// What a set of files and folders adds up to (spec 07 › Calculate occupied space).
struct SpaceTotals: Equatable {
    /// The sum of the file sizes.
    var bytes: Int64 = 0
    /// The space really taken on the source volume; equal to `bytes` where that is not known.
    var allocated: Int64 = 0
    /// The file sizes rounded up to the allocation unit of the target volume: the space a
    /// copy needs there.
    var rounded: Int64 = 0
    var files = 0
    var folders = 0
    /// Folders that could not be read; their contents are missing from the figures.
    var unreadable = 0

    static func + (left: SpaceTotals, right: SpaceTotals) -> SpaceTotals {
        SpaceTotals(bytes: left.bytes.addingSaturated(right.bytes), allocated: left.allocated.addingSaturated(right.allocated),
                    rounded: left.rounded.addingSaturated(right.rounded),
                    files: left.files + right.files, folders: left.folders + right.folders, unreadable: left.unreadable + right.unreadable)
    }
}

/// Counts finished items from any thread and passes the count on to a job's progress window:
/// at most twenty times a second, one thread at a time (the lock is held while reporting, so a
/// `JobMonitor`, which expects one reporting thread, sees one at a time). Whichever thread
/// comes by reports, because the job's own thread may be waiting for the others or deep in one
/// slow folder; a paused job then stops the threads that come by, which is what Pause is for.
final class ProgressMeter {
    private let monitor: JobMonitor
    private let title: String
    private let total: Int
    private let lock = NSLock()
    private var done = 0
    private var lastReport = Date.distantPast

    /// `total` is 0 when the number of items is not known in advance.
    init(_ monitor: JobMonitor, title: String, total: Int = 0) {
        self.monitor = monitor
        self.title = title
        self.total = total
    }

    func add(_ count: Int, at location: @autoclosure () -> String) {
        lock.lock()
        defer { lock.unlock() }
        done += count
        let now = Date()
        guard now.timeIntervalSince(lastReport) > 0.05 else { return }
        lastReport = now
        monitor.report(JobProgress(lines: [title, location()], itemsDone: done, itemsTotal: total))
    }
}

/// Measures files and whole trees through their file-system providers.
///
/// **Threading.** `measure` blocks and is meant for a job's thread. The subfolders of every
/// folder are measured on all cores at once (`Parallel.map`); each branch adds up its own
/// figures and hands them back, so nothing is shared between the threads but the cancellation
/// flag and the progress meter, which protect themselves.
struct SpaceCalculator {
    let fileSystems: FileSystemRegistry
    var cancellation = CancellationFlag()
    /// The allocation unit of the volume a copy would go to; nil rounds nothing.
    var targetCluster: Int64?
    var meter: ProgressMeter?
    /// Whether the space really taken on the disk is asked for, which costs one more call per
    /// file; "Calculate all folder sizes" shows sizes only.
    var measuresAllocated = true

    /// One figure per item, in the same order. A folder counts itself and everything below.
    func measure(_ items: [FileItem]) -> [SpaceTotals] {
        Parallel.map(items) { item in
            item.isRealDirectory ? measure(directory: item.url) + SpaceTotals(folders: 1) : measure(file: item)
        }
    }

    private func measure(file item: FileItem) -> SpaceTotals {
        // Only the Mac's own file system says how much room a file really takes.
        let allocated = measuresAllocated && item.url.isFileURL ? LocalInfo.details(item.url)?.allocated ?? item.size : item.size
        return SpaceTotals(bytes: item.size, allocated: allocated, rounded: SpaceCalculator.round(item.size, to: targetCluster), files: 1)
    }

    static func round(_ size: Int64, to cluster: Int64?) -> Int64 {
        guard let cluster, cluster > 1 else { return size }
        return size.addingSaturated(cluster - 1) / cluster * cluster
    }

    /// Everything below a directory, not counting the directory itself. Links are counted as
    /// the links they are and never followed.
    func measure(directory: URL) -> SpaceTotals {
        guard !cancellation.isCancelled else { return SpaceTotals() }
        // Listed with the flag: a folder on a server that has stopped answering ends when the
        // job is cancelled, and does not keep a thread of the pool.
        guard let items = try? fileSystems.provider(for: directory).list(directory, showHidden: true, cancellation: cancellation) else {
            return cancellation.isCancelled ? SpaceTotals() : SpaceTotals(unreadable: 1)
        }
        // A listing that ended because of the cancel is not the whole folder.
        guard !cancellation.isCancelled else { return SpaceTotals() }
        var totals = SpaceTotals()
        var folders: [URL] = []
        for item in items {
            if item.isRealDirectory {
                folders.append(item.url)
            } else {
                totals = totals + measure(file: item)
            }
        }
        totals.folders += folders.count
        meter?.add(items.count, at: fileSystems.displayPath(directory))
        return Parallel.map(folders) { measure(directory: $0) }.reduce(totals, +)
    }
}

/// The wording of the result box of Calculate Occupied Space.
enum SpaceReport {
    static func text(_ totals: SpaceTotals, sourceIsLocal: Bool, targetCluster: Int64?, volume: VolumeInfo?, cancelled: Bool) -> String {
        var lines = ["\(Format.bytes(totals.bytes)) bytes in \(Format.bytes(Int64(totals.files))) file(s)"]
        if totals.folders > 0 { lines[0] += ",\nin \(Format.bytes(Int64(totals.folders))) directories" }
        if totals.bytes >= 1024 { lines.append("(= \(Format.kilobytes(totals.bytes)), \(Format.shortSize(totals.bytes)))") }
        if sourceIsLocal || targetCluster != nil { lines.append("") }
        if sourceIsLocal { lines.append("Actual space used on source volume: \(Format.bytes(totals.allocated)) bytes") }
        if targetCluster != nil { lines.append("Required on target volume: \(Format.bytes(totals.rounded)) bytes") }
        if let volume, let free = volume.freeBytes, let total = volume.totalBytes {
            lines += ["", "\(volume.name): \(Format.kilobytes(free)) of \(Format.kilobytes(total)) free"]
        }
        if totals.unreadable > 0 { lines += ["", "\(totals.unreadable) folder(s) could not be read and are not counted."] }
        if cancelled { lines += ["", "The calculation was stopped; the figures are incomplete."] }
        return lines.joined(separator: "\n")
    }
}
