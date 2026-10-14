import Foundation

/// A group of entries in the context menu of the file list.
public struct ContextMenuSection: Hashable, Sendable {
    public let order: Int

    public init(order: Int) {
        self.order = order
    }
}
