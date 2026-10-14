import AFMKernel
import Foundation

/// The texts of the plugin columns of one panel (spec 03 › Custom columns).
///
/// A column's value may be slow to get (it may read the file), so it is never computed on the
/// main thread. The list asks for the value of a row when it draws it; a value that is not
/// known yet is put in line and the cell stays empty. The line is worked off in batches on a
/// background queue, each batch spread over all cores, the rows asked for last first, because
/// those are the ones on screen. When a batch is done its values are kept and `onArrival`
/// names the rows to draw again. Scrolling never waits for any of this.
///
/// A batch runs in the lane of the folder it is for (`Background`), one batch per folder at a
/// time. A value that never comes (a file on a share that stopped answering) therefore holds
/// up the values of that folder only: the next folder the panel shows gets its values on a
/// lane of its own, and coming back to the folder starts nothing behind the batch that is stuck.
///
/// **Threading.** Everything in here belongs to the main thread; a batch takes copies of what
/// it needs to the background and brings its results back. The column's own `value` function
/// is called on several background threads at once, as its contract says.
final class ColumnValueStore {
    /// A value belongs to a column and to an entry as it was listed: a file that changed gets
    /// its value computed again.
    private struct Key: Hashable {
        let column: String
        let name: String
        let size: Int64
        let modified: Date
    }

    private struct Request {
        let key: Key
        let column: ContentColumn
        let item: FileItem
    }

    private var values: [Key: String] = [:]
    /// What is waiting, oldest first; the end of the line is served first.
    private var waiting: [Request] = []
    private var asked: Set<Key> = []
    /// The folder the values are for, and the folders a batch is out for.
    private var folder: URL?
    private var location: String { folder?.locationKey ?? "" }
    private var working: Set<String> = []
    /// Counts the folders shown; a batch that returns for an earlier one is dropped.
    private var generation = 0
    /// Set when the panel leaves the folder: a column that reads its file or asks a server
    /// gives up then (`ContentColumn.cancellableValue`), and the lane is free for the next folder.
    private var cancellation = CancellationFlag()
    /// Called on the main thread with the names of the entries whose values arrived.
    var onArrival: ((Set<String>) -> Void)?

    /// Rows computed in one go: a few per core, so the rows scrolled to meanwhile get their turn soon.
    static var batchSize: Int { max(16, ProcessInfo.processInfo.activeProcessorCount * 4) }

    /// The value, when it is known; otherwise nil, and the value is on its way.
    func text(of column: ContentColumn, for item: FileItem) -> String? {
        MainThread.assert("The column values")
        let key = Key(column: column.id, name: item.name, size: item.size, modified: item.modified)
        if let value = values[key] { return value }
        if asked.insert(key).inserted {
            waiting.append(Request(key: key, column: column, item: item))
            work()
        }
        return nil
    }

    /// True while requests wait for their turn.
    var hasWaiting: Bool { !waiting.isEmpty }

    /// True while values are being computed or wait for it.
    var isBusy: Bool { working.contains(location) || !waiting.isEmpty }

    /// Drops the requests that wait for rows that are no longer on screen (their names are not in
    /// `names`); they are asked for again if the rows come back. A batch that is being computed
    /// is finished.
    func dropWaiting(except names: Set<String>) {
        MainThread.assert("The column values")
        guard !waiting.isEmpty else { return }
        for request in waiting where !names.contains(request.item.name) { asked.remove(request.key) }
        waiting.removeAll { !names.contains($0.item.name) }
    }

    /// Forgets everything: the panel shows another folder, `folder`.
    func reset(folder: URL? = nil) {
        MainThread.assert("The column values")
        self.folder = folder
        generation += 1
        cancellation.cancel()
        cancellation = CancellationFlag()
        values = [:]
        waiting = []
        asked = []
    }

    private func work() {
        let location = location
        guard !working.contains(location), !waiting.isEmpty else { return }
        working.insert(location)
        let count = min(ColumnValueStore.batchSize, waiting.count)
        let batch = Array(waiting.suffix(count).reversed())
        waiting.removeLast(count)
        let generation = self.generation
        let lane = folder ?? URL(fileURLWithPath: "/")
        let flag = cancellation
        Background.storage("columns", at: lane, qos: .utility, work: { Parallel.map(batch) { $0.column.cancellableValue($0.item, flag) } },
                           then: { [weak self] texts in
            guard let self else { return }
            self.working.remove(location)
            if generation == self.generation {
                for (request, text) in zip(batch, texts) { self.values[request.key] = text }
                self.onArrival?(Set(batch.map(\.item.name)))
            }
            self.work()
        })
    }
}
