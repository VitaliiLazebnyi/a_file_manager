import Foundation

/// A menu of the menu bar.
///
/// Menus are shown in the order of their `order` values.
public struct MenuID: Hashable, Sendable {
    /// The title in the menu bar; it also tells two menus apart.
    public let title: String
    /// Where the menu goes in the menu bar: lower values further left.
    public let order: Int

    /// The menu called `title`, at place `order` in the menu bar.
    public init(_ title: String, order: Int) {
        self.title = title
        self.order = order
    }
}
