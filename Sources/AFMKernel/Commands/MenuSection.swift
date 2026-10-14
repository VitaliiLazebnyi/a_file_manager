import Foundation

/// A group of entries inside a menu; groups are shown in the order of their `order` values,
/// with a separator between them. Plugins that share a section share one constant.
public struct MenuSection: Hashable, Sendable {
    public let menu: MenuID
    public let order: Int

    public init(_ menu: MenuID, order: Int) {
        self.menu = menu
        self.order = order
    }
}
