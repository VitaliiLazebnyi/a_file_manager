/// A group of entries in the context menu of the file list.
public struct ContextMenuSection: Hashable, Sendable {
    /// Where the section goes in the menu: lower values higher up.
    public let order: Int

    /// The section at place `order` in the context menu.
    public init(order: Int) {
        self.order = order
    }
}
