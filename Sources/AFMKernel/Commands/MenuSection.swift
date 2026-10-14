import Foundation

/// A group of entries inside a menu; groups are shown in the order of their `order` values, with a separator between
/// them.
///
/// Plugins that share a section share one constant.
public struct MenuSection: Hashable, Sendable {
    /// The menu the section is in.
    public let menu: MenuID
    /// Where the section goes in its menu: lower values higher up.
    public let order: Int

    /// The section at place `order` in `menu`.
    public init(_ menu: MenuID, order: Int) {
        self.menu = menu
        self.order = order
    }
}
