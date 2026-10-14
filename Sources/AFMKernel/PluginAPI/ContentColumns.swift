import Foundation

/// A column a plugin adds to the file list: a piece of information about a file that the
/// kernel knows nothing of (a comment, an owner, a checksum). This is what content plugins are
/// in the specification (15 › Content plugins, 03 › Custom columns).
public struct ContentColumn {
    /// Unique among all columns, e.g. `comment`.
    public let id: String
    public let title: String
    /// Width in points the column starts with.
    public let width: Int
    public let alignsRight: Bool
    /// The text of a row. May block on the file system: it is called on background threads,
    /// several at once, and the panel keeps the answers for as long as it shows the folder.
    public let value: (FileItem) -> String
    /// The same for a caller that can give up: the flag is set when the answer is no longer
    /// wanted (the panel has left the folder), and a column that reads the file ends its
    /// reading then and returns whatever it has. Every column has it; one that was made
    /// without a flag answers as `value` does.
    public let cancellableValue: (FileItem, CancellationFlag) -> String

    public init(
        id: String, title: String, width: Int = 120, alignsRight: Bool = false, value: @escaping (FileItem) -> String
    ) {
        self.id = id
        self.title = title
        self.width = width
        self.alignsRight = alignsRight
        self.value = value
        cancellableValue = { item, cancellation in cancellation.isCancelled ? "" : value(item) }
    }

    /// A column whose text can take long to find out (it reads the file, or asks a server).
    public init(
        id: String, title: String, width: Int = 120, alignsRight: Bool = false,
        cancellableValue: @escaping (FileItem, CancellationFlag) -> String
    ) {
        self.id = id
        self.title = title
        self.width = width
        self.alignsRight = alignsRight
        self.cancellableValue = cancellableValue
        value = { cancellableValue($0, CancellationFlag()) }
    }
}

/// The columns plugins offer. Filled while the plugins start and only read afterwards, so it
/// may be read from any thread. Which of them a panel shows is the panel's state
/// (`PanelHandle.extraColumns`).
public final class ColumnRegistry {
    private var columns: [ContentColumn] = []

    public init() {}

    public func register(_ column: ContentColumn) {
        precondition(!columns.contains { $0.id == column.id }, "The column \(column.id) is registered twice")
        columns.append(column)
    }

    /// Every column, in registration order.
    public var all: [ContentColumn] { columns }

    public subscript(id: String) -> ContentColumn? { columns.first { $0.id == id } }
}
