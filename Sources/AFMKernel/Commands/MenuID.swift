import Foundation

/// A menu of the menu bar. Menus are shown in the order of their `order` values.
public struct MenuID: Hashable, Sendable {
    public let title: String
    public let order: Int

    public init(_ title: String, order: Int) {
        self.title = title
        self.order = order
    }
}
