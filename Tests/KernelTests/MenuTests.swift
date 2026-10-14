import AFMKernel
import Testing

/// The menu registry: menus and their sections, and the context menu.
@MainActor
@Suite
internal struct MenuTests {
    /// The menu "Files", early in the menu bar.
    private static let files = MenuID("Files", order: 10)
    /// The menu "Show", after it.
    private static let show = MenuID("Show", order: 50)

    /// Menus come in their order; inside one, sections come in theirs, apart by separators,
    /// and entries of one section in the order they were added.
    @Test
    internal func menusAreOrderedAndGrouped() {
        let menus = MenuRegistry()
        menus.add(["sort"], to: MenuSection(Self.show, order: 10))
        menus.add(["copy", "move"], to: MenuSection(Self.files, order: 20))
        menus.add(["open"], to: MenuSection(Self.files, order: 10))
        menus.add(["view"], to: MenuSection(Self.files, order: 10))
        menus.add(["delete"], to: MenuSection(Self.files, order: 40))
        #expect(menus.menus.map(\.title) == ["Files", "Show"])
        #expect(menus.menus[0].items == ["open", "view", nil, "copy", "move", nil, "delete"])
    }

    /// Entries meant for an item are shown only when the menu is opened on one.
    @Test
    internal func contextMenuLeavesOutItemEntriesOnEmptySpace() {
        let menus = MenuRegistry()
        menus.addToContextMenu(["open"], in: ContextMenuSection(order: 10), onItemOnly: true)
        menus.addToContextMenu(["paste"], in: ContextMenuSection(order: 20))
        menus.addToContextMenu(["copy"], in: ContextMenuSection(order: 20), onItemOnly: true)
        #expect(menus.contextMenu(onItem: true) == ["open", nil, "paste", "copy"])
        #expect(menus.contextMenu(onItem: false) == ["paste"])
    }
}
