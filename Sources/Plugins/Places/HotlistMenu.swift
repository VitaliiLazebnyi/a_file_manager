/// The hotlist as the Ctrl+D pop-up shows one level of it: the visible entries, then the two
/// fixed items (spec 12 › The hotlist menu).
public struct HotlistMenu {
    /// What choosing a row does.
    public enum Action: Equatable {
        /// Runs the entry's command (and shows its target).
        case run(HotlistEntry)
        /// A submenu: its entries are shown next.
        case open(Hotlist.Path)
        /// The Mac's standard folders, shown as a submenu of their own.
        case openFavorites
        /// A separator line; it cannot be chosen.
        case separator
        /// "Add current dir": adds the panel's directory on this level.
        case addCurrent
        /// The current directory is listed on this level; choosing the item removes it.
        case removeCurrent(Hotlist.Path)
        /// "Configure…": opens the hotlist editor.
        case configure
    }

    /// One line of the pop-up.
    public struct Row: Equatable {
        /// The text shown, with its mark.
        public let title: String
        /// What choosing the row does.
        public let action: Action
    }

    /// The text of a separator row.
    internal static let separatorTitle = "────────────"

    /// The rows, top to bottom.
    public let rows: [Row]
    /// The row the list opens on: the entry of the current directory, or the first.
    public let selected: Int

    /// The text of each row, in the order of `rows`.
    public var titles: [String] { rows.map(\.title) }

    /// One level of the user's list, at `path`, with the Favorites submenu on the top level when `offersFavorites`.
    ///
    /// `isCurrent` tells whether an entry leads to the directory
    /// the panel shows; such entries, and the submenus holding one, are marked.
    public init(
        _ hotlist: Hotlist,
        at path: Hotlist.Path = [],
        offersFavorites: Bool = false,
        isCurrent: (HotlistEntry) -> Bool
    ) {
        var lines: [Row] = []
        var current: Hotlist.Path?
        var opening: Int?
        for (index, entry) in hotlist.children(of: path).enumerated() where !hotlist.isHidden(entry) {
            let marked = Hotlist.contains(entry) { $0.kind == .item && isCurrent($0) }
            if marked, opening == nil {
                opening = lines.count
            }
            switch entry.kind {
            case .separator:
                lines.append(Row(title: Self.separatorTitle, action: .separator))

            case .submenu:
                lines.append(
                    Row(title: Self.mark(marked) + entry.displayTitle + "  ▸", action: .open(path + [index]))
                )

            case .item:
                if marked, current == nil {
                    current = path + [index]
                }
                lines.append(Row(title: Self.mark(marked) + entry.displayTitle, action: .run(entry)))
            }
        }
        if !lines.isEmpty {
            lines.append(Row(title: Self.separatorTitle, action: .separator))
        }
        if offersFavorites, path.isEmpty {
            lines.append(Row(title: Self.mark(false) + "Favorites  ▸", action: .openFavorites))
        }
        lines.append(
            current.map { Row(title: "− Remove current dir", action: .removeCurrent($0)) }
                ?? Row(title: "+ Add current dir", action: .addCurrent)
        )
        lines.append(Row(title: "* Configure…", action: .configure))
        rows = lines
        selected = opening ?? 0
    }

    /// A fixed list of places without the editing items (the Mac's Favorites).
    public init(places: [HotlistEntry], isCurrent: (HotlistEntry) -> Bool) {
        rows = places.map { Row(title: Self.mark(isCurrent($0)) + $0.displayTitle, action: .run($0)) }
        selected = places.firstIndex(where: isCurrent) ?? 0
    }

    /// The mark before a title: a check for the current directory, else spaces of the same width.
    private static func mark(_ isCurrent: Bool) -> String { isCurrent ? "✓ " : "    " }
}
