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
@MainActor
internal final class ColumnValueStore {
    /// A value belongs to a column and to an entry as it was listed: a file that changed gets
    /// its value computed again.
    private struct Key: Hashable {
        /// The column's id.
        let column: String
        /// The entry's name.
        let name: String
        /// The entry's size when it was listed.
        let size: Int64
        /// The entry's date when it was listed.
        let modified: Date

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.column == rhs.column && lhs.name == rhs.name && lhs.size == rhs.size && lhs.modified == rhs.modified
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(column)
            hasher.combine(name)
            hasher.combine(size)
            hasher.combine(modified)
        }
    }

    /// One value that is wanted: for which column and entry.
    private struct Request {
        /// What the value is kept under.
        let key: Key
        /// The column that computes it.
        let column: ContentColumn
        /// The entry it is computed for.
        let item: FileItem
    }

    /// Rows computed in one go: a few per core, so the rows scrolled to meanwhile get their turn soon.
    internal static var batchSize: Int { max(16, ProcessInfo.processInfo.activeProcessorCount * 4) }

    /// Called on the main thread with the names of the entries whose values arrived.
    internal var onArrival: ((Set<String>) -> Void)?
    /// The folders (`URL.locationKey`) a batch is out for.
    internal private(set) var working: Set<String> = []

    private var values: [Key: String] = [:]
    /// What is waiting, oldest first; the end of the line is served first.
    private var waiting: [Request] = []
    private var asked: Set<Key> = []
    /// The folder the values are for.
    private var folder: URL?
    /// Counts the folders shown; a batch that returns for an earlier one is dropped.
    private var generation = 0
    /// Set when the panel leaves the folder: a column that reads its file or asks a server
    /// gives up then (`ContentColumn.cancellableValue`), and the lane is free for the next folder.
    private var cancellation = CancellationFlag()

    /// True while requests wait for their turn.
    internal var hasWaiting: Bool { !waiting.isEmpty }

    private var location: String { folder?.locationKey ?? "" }

    /// Nothing known and nothing asked for yet.
    internal init() {
        // Every value is asked for when a row is drawn.
    }

    /// The value, when it is known; otherwise nil, and the value is on its way.
    internal func text(of column: ContentColumn, for item: FileItem) -> String? {
        let key = Key(column: column.id, name: item.name, size: item.size, modified: item.modified)
        if let value = values[key] {
            return value
        }
        if asked.insert(key).inserted {
            waiting.append(Request(key: key, column: column, item: item))
            work()
        }
        return nil
    }

    /// Drops the requests that wait for rows that are no longer on screen (their names are not in
    /// `names`); they are asked for again if the rows come back.
    ///
    /// A batch that is being computed is finished.
    internal func dropWaiting(except names: Set<String>) {
        guard !waiting.isEmpty else {
            return
        }
        for request in waiting where !names.contains(request.item.name) {
            asked.remove(request.key)
        }
        waiting.removeAll { !names.contains($0.item.name) }
    }

    /// Forgets everything: the panel shows another folder, `folder` (nil for none).
    internal func reset(folder: URL?) {
        self.folder = folder
        generation += 1
        cancellation.cancel()
        cancellation = CancellationFlag()
        values = [:]
        waiting = []
        asked = []
    }

    /// Starts the next batch of the folder shown, unless one is out for it already.
    private func work() {
        let shown = location
        guard !working.contains(shown), !waiting.isEmpty else {
            return
        }
        working.insert(shown)
        let count = min(Self.batchSize, waiting.count)
        let batch = Array(waiting.suffix(count).reversed())
        waiting.removeLast(count)
        let lane = folder ?? URL(fileURLWithPath: "/")
        let flag = cancellation
        let batchGeneration = generation
        Background.storage(
            "columns",
            at: lane,
            qos: .utility,
            work: { Parallel.map(batch) { $0.column.cancellableValue($0.item, flag) } },
            then: { [weak self] texts in self?.take(texts, of: batch, for: shown, generation: batchGeneration) }
        )
    }

    /// A batch came back: its values are kept unless the folder was left meanwhile, and the
    /// next batch starts.
    private func take(_ texts: [String], of batch: [Request], for location: String, generation: Int) {
        working.remove(location)
        if generation == self.generation {
            for (request, text) in zip(batch, texts) {
                values[request.key] = text
            }
            onArrival?(Set(batch.map(\.item.name)))
        }
        work()
    }

    deinit {
        // Nothing to release: a batch out holds no reference to the store.
    }
}
