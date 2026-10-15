import Foundation
import os

/// The columns plugins offer.
///
/// Filled while the plugins start and only read afterwards, so it may be read from any thread. Which of them a panel
/// shows is the panel's state (`PanelHandle.extraColumns`).
///
/// Unchecked: `columns` is guarded by `lock`, so a late registration cannot race a reader.
public final class ColumnRegistry: @unchecked Sendable {
    private static let log = Log.logger("Kernel")

    private let lock = NSLock()
    private var columns: [ContentColumn] = []

    /// Every column, in registration order.
    public var all: [ContentColumn] { lock.withLock { columns } }

    /// An empty registry; the kernel makes the one the plugins fill.
    public init() {
        // Columns come with the plugins.
    }

    /// Offers a column.
    ///
    /// Any thread; an id that is taken already is a bug of the plugin.
    public func register(_ column: ContentColumn) {
        lock.lock()
        defer { lock.unlock() }
        guard !columns.contains(where: { $0.id == column.id }) else {
            Self.log.fault("The column \(column.id, privacy: .public) is registered twice; the first stays")
            return
        }
        columns.append(column)
    }

    /// The column with this id; nil when no plugin offers it.
    ///
    /// Any thread.
    public subscript(id: String) -> ContentColumn? { lock.withLock { columns.first { $0.id == id } } }

    deinit {
        // Nothing to release.
    }
}
