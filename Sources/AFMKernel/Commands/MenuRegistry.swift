import os

/// Where plugins say in which menus their commands appear.
///
/// The shell builds the menu bar and the context menu from this; it has no menu layout of its own.
@preconcurrency
@MainActor
public final class MenuRegistry {
    /// A menu of the menu bar as the shell builds it.
    public struct Menu: Sendable {
        /// The menu's title in the menu bar.
        public let title: String
        /// Commands in display order; `nil` is a separator between sections.
        public let items: [CommandID?]
    }

    /// Commands a plugin put into the context menu, with the section they go into.
    private struct ContextEntry {
        let section: ContextMenuSection
        let items: [CommandID]
        let onItemOnly: Bool
    }

    private static let log = Log.logger("Kernel")
    /// The menus by title: two plugins that name a menu alike must mean the same one.
    private var menuIDs: [String: MenuID] = [:]
    private var entries: [(section: MenuSection, items: [CommandID])] = []
    private var contextEntries: [ContextEntry] = []

    /// The menus of the menu bar, in order.
    public var menus: [Menu] {
        menuIDs.values.sorted { ($0.order, $0.title) < ($1.order, $1.title) }
            .map { menu in
                Menu(
                    title: menu.title,
                    items: Self.flatten(
                        entries.filter { $0.section.menu == menu }.map { ($0.section.order, $0.items) }
                    )
                )
            }
    }

    /// An empty registry; the plugins fill it while they start.
    public init() {
        // Nothing is in the menus yet.
    }

    /// Commands in the order of their sections, with a separator (nil) between two sections.
    private static func flatten(_ contributions: [(order: Int, items: [CommandID])]) -> [CommandID?] {
        var items: [CommandID?] = []
        for (_, group) in Dictionary(grouping: contributions, by: \.order).sorted(by: { $0.key < $1.key }) {
            if !items.isEmpty { items.append(nil) }
            items += group.flatMap(\.items).map(Optional.some)
        }
        return items
    }

    /// Adds commands to a section of the menu bar.
    ///
    /// Inside a section, commands appear in the order they were added (the order the plugins were loaded in).
    public func add(_ items: [CommandID], to section: MenuSection) {
        let menu = section.menu
        if let known = menuIDs[menu.title], known != menu {
            Self.log.fault("Two different menus are called \(menu.title, privacy: .public); the first stays")
            entries.append((MenuSection(known, order: section.order), items))
            return
        }
        menuIDs[menu.title] = menu
        entries.append((section, items))
    }

    /// Adds commands to the context menu of the file list. `onItemOnly` entries are left out
    /// when the menu is opened on empty space or on `[..]`.
    public func addToContextMenu(_ items: [CommandID], in section: ContextMenuSection, onItemOnly: Bool = false) {
        contextEntries.append(ContextEntry(section: section, items: items, onItemOnly: onItemOnly))
    }

    /// The context menu of the file list, opened on an item or (`onItem` false) on empty
    /// space or `[..]`; nil is a separator.
    public func contextMenu(onItem: Bool) -> [CommandID?] {
        Self.flatten(contextEntries.filter { onItem || !$0.onItemOnly }.map { ($0.section.order, $0.items) })
    }

    deinit {
        // Nothing to release.
    }
}
