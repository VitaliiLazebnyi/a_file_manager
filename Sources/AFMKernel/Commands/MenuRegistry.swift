import Foundation

/// Where plugins say in which menus their commands appear. The shell builds the menu bar and
/// the context menu from this; it has no menu layout of its own.
@MainActor
public final class MenuRegistry {
    public struct Menu: Sendable {
        public let title: String
        /// Commands in display order; `nil` is a separator between sections.
        public let items: [CommandID?]
    }

    private struct ContextEntry {
        let section: ContextMenuSection
        let items: [CommandID]
        let onItemOnly: Bool
    }

    private var menus_: [String: MenuID] = [:]
    private var entries: [(section: MenuSection, items: [CommandID])] = []
    private var contextEntries: [ContextEntry] = []

    public init() {}

    /// Adds commands to a section of the menu bar. Inside a section, commands appear in the
    /// order they were added (the order the plugins were loaded in).
    public func add(_ items: [CommandID], to section: MenuSection) {
        let menu = section.menu
        precondition(
            menus_[menu.title] == nil || menus_[menu.title] == menu,
            "Two different menus are called \(menu.title); plugins must share one MenuID"
        )
        menus_[menu.title] = menu
        entries.append((section, items))
    }

    /// Adds commands to the context menu of the file list. `onItemOnly` entries are left out
    /// when the menu is opened on empty space or on `[..]`.
    public func addToContextMenu(_ items: [CommandID], in section: ContextMenuSection, onItemOnly: Bool = false) {
        contextEntries.append(ContextEntry(section: section, items: items, onItemOnly: onItemOnly))
    }

    /// The menus of the menu bar, in order.
    public var menus: [Menu] {
        menus_.values.sorted { ($0.order, $0.title) < ($1.order, $1.title) }
            .map { menu in
                Menu(
                    title: menu.title,
                    items: Self.flatten(
                        entries.filter { $0.section.menu == menu }.map { ($0.section.order, $0.items) }
                    )
                )
            }
    }

    public func contextMenu(onItem: Bool) -> [CommandID?] {
        Self.flatten(contextEntries.filter { onItem || !$0.onItemOnly }.map { ($0.section.order, $0.items) })
    }

    private static func flatten(_ contributions: [(order: Int, items: [CommandID])]) -> [CommandID?] {
        let groups = Dictionary(grouping: contributions, by: \.order)
        var items: [CommandID?] = []
        for order in groups.keys.sorted() {
            if !items.isEmpty { items.append(nil) }
            items += groups[order]!.flatMap(\.items).map(Optional.some)
        }
        return items
    }
}
