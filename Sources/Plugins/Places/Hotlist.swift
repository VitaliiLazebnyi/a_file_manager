public import AFMKernel
public import Foundation

/// One line of the directory hotlist (spec 12 › Directory hotlist editor): a place to go to,
/// a submenu of further entries, or a separator line.
public struct HotlistEntry: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case item, submenu, separator
    }

    public static let separator = Self(kind: .separator, title: "-")

    public var kind: Kind
    /// As the user typed it; an `&` marks the letter after it (spec 12 › Editing entries).
    public var title: String
    /// What choosing the entry does: `cd <path>` or the name of a command (`HotlistAction`).
    public var command: String
    /// Shown in the other panel at the same time; empty for none.
    public var target: String
    public var children: [Self]

    /// The title as it is shown: without the `&` that marks an accelerator (`&&` is an ampersand).
    public var displayTitle: String {
        title.replacingOccurrences(of: "&&", with: "\u{0}").replacingOccurrences(of: "&", with: "")
            .replacingOccurrences(of: "\u{0}", with: "&")
    }

    public init(kind: Kind, title: String, command: String = "", target: String = "", children: [Self] = []) {
        self.kind = kind
        self.title = title
        self.command = command
        self.target = target
        self.children = children
    }

    public static func item(_ title: String, command: String, target: String = "") -> Self {
        Self(kind: .item, title: title, command: command, target: target)
    }

    public static func submenu(_ title: String, _ children: [Self] = []) -> Self {
        Self(kind: .submenu, title: title, children: children)
    }

    /// An entry for what the user typed as a title: a single `-` makes a separator.
    public static func titled(_ title: String, command: String) -> Self {
        title.trimmingCharacters(in: .whitespaces) == "-" ? .separator : .item(title, command: command)
    }
}

/// The directory hotlist: the user's bookmarks, with submenus and separators (spec 03 ›
/// Directory hotlist).
///
/// A value: the plugin reads it from the settings, changes it and writes it back, on the main
/// thread.
public struct Hotlist: Codable, Equatable {
    /// The position of an entry: its index on the top level, then inside each submenu.
    public typealias Path = [Int]

    /// One line of the list written out flat, as the editor shows it.
    public struct Row: Equatable {
        public let path: Path
        public let entry: HotlistEntry
        public var depth: Int { path.count - 1 }
    }

    /// The most entries the list takes (spec 12 › Storage and limits).
    public static let limit = 2_000

    public var entries: [HotlistEntry]
    /// Entries whose title starts with this are hidden while `hidesMarked` is on.
    public var hideCharacter: String
    public var hidesMarked: Bool

    /// Every entry in display order, submenus followed by what they hold.
    public var rows: [Row] {
        func rows(_ entries: [HotlistEntry], _ prefix: Path) -> [Row] {
            entries.enumerated()
                .flatMap { index, entry in
                    [Row(path: prefix + [index], entry: entry)] + rows(entry.children, prefix + [index])
                }
        }
        return rows(entries, [])
    }

    public var count: Int { rows.count }

    public init(entries: [HotlistEntry] = [], hideCharacter: String = "?", hidesMarked: Bool = false) {
        self.entries = entries
        self.hideCharacter = hideCharacter
        self.hidesMarked = hidesMarked
    }

    /// Keeps the first `room` entries (submenus and what they hold count one each, in display
    /// order) and drops the rest; `room` is what is left.
    ///
    /// Returns how many were dropped. Without recursion into more than the entries that stay.
    internal static func trimmed(_ entries: inout [HotlistEntry], room: inout Int) -> Int {
        var dropped = 0
        var kept: [HotlistEntry] = []
        for var entry in entries {
            guard room > 0 else {
                dropped += 1 + entry.children.reduce(0) { $0 + Self.size(of: $1) }
                continue
            }
            room -= 1
            dropped += trimmed(&entry.children, room: &room)
            kept.append(entry)
        }
        entries = kept
        return dropped
    }

    private static func size(of entry: HotlistEntry) -> Int {
        1 + entry.children.reduce(0) { $0 + size(of: $1) }
    }

    /// Whether the entry, or anything inside it, `matches`.
    public static func contains(_ entry: HotlistEntry, where matches: (HotlistEntry) -> Bool) -> Bool {
        matches(entry) || entry.children.contains { contains($0, where: matches) }
    }

    // MARK: Reading

    /// The entries of the top level (an empty path) or of a submenu; empty when there is none.
    public func children(of path: Path) -> [HotlistEntry] {
        path.isEmpty ? entries : (entry(at: path)?.children ?? [])
    }

    public func entry(at path: Path) -> HotlistEntry? {
        var level = entries
        var found: HotlistEntry?
        for index in path {
            guard level.indices.contains(index) else {
                return nil
            }
            found = level[index]
            level = level[index].children
        }
        return found
    }

    /// Hidden from the Ctrl+D menu right now (spec 12 › Hiding entries).
    public func isHidden(_ entry: HotlistEntry) -> Bool {
        hidesMarked && !hideCharacter.isEmpty && entry.kind != .separator && entry.title.hasPrefix(hideCharacter)
    }

    /// The first entry of one level that `matches`, as an index into that level.
    public func index(in parent: Path, where matches: (HotlistEntry) -> Bool) -> Int? {
        children(of: parent).firstIndex(where: matches)
    }

    // MARK: Changing

    /// Runs `body` on the entries of one level; nil when the level does not exist.
    private mutating func withChildren<Result>(of path: Path, _ body: (inout [HotlistEntry]) -> Result) -> Result? {
        func descend(_ level: inout [HotlistEntry], _ rest: ArraySlice<Int>) -> Result? {
            guard let index = rest.first else {
                return body(&level)
            }
            guard level.indices.contains(index), level[index].kind == .submenu else {
                return nil
            }
            return descend(&level[index].children, rest.dropFirst())
        }
        return descend(&entries, ArraySlice(path))
    }

    /// Puts an entry at `path`, moving what is there down; an index past the end appends.
    ///
    /// Returns where it landed, or nil when the level does not exist or the list is full.
    @discardableResult
    public mutating func insert(_ entry: HotlistEntry, at path: Path) -> Path? {
        guard let index = path.last, count < Self.limit else {
            return nil
        }
        let parent = Array(path.dropLast())
        return withChildren(of: parent) { level in
            let position = min(max(index, 0), level.count)
            level.insert(entry, at: position)
            return parent + [position]
        }
    }

    /// Adds an entry to a level the way "Add current dir" does: at the end of the level, but
    /// before the submenus it ends with (spec 12 › The hotlist menu).
    @discardableResult
    public mutating func add(_ entry: HotlistEntry, to parent: Path) -> Path? {
        let level = children(of: parent)
        var position = level.count
        if !parent.isEmpty {
            while position > 0, level[position - 1].kind == .submenu { position -= 1 }
        }
        return insert(entry, at: parent + [position])
    }

    @discardableResult
    public mutating func remove(at path: Path) -> HotlistEntry? {
        guard let index = path.last else {
            return nil
        }
        return withChildren(of: Array(path.dropLast())) { level in
            level.indices.contains(index) ? level.remove(at: index) : nil
        } ?? nil
    }

    /// Changes the entry at `path` in place; false when there is none.
    @discardableResult
    public mutating func update(at path: Path, _ change: (inout HotlistEntry) -> Void) -> Bool {
        guard let index = path.last else {
            return false
        }
        return withChildren(of: Array(path.dropLast())) { level in
            guard level.indices.contains(index) else {
                return false
            }
            change(&level[index])
            return true
        } ?? false
    }

    /// Shift+Up / Shift+Down in the editor: moves an entry one line.
    ///
    /// Past the edge of a submenu it leaves the submenu, and next to a submenu it enters it, so
    /// every position can be reached as in a flat list. Returns the entry's new position; the same
    /// path when nothing moved.
    ///
    /// Each move takes the entry out and puts it back within one level of the list, so it is
    /// never lost or doubled, also in a list read from damaged data (an item holding entries,
    /// which the editor shows but which is no submenu).
    @discardableResult
    public mutating func move(at path: Path, by direction: Int) -> Path {
        guard let index = path.last, direction != 0 else {
            return path
        }
        let parent = Array(path.dropLast())
        let step = direction < 0 ? -1 : 1
        let inside = withChildren(of: parent) { level -> Path? in
            let neighbour = index + step
            guard level.indices.contains(index), level.indices.contains(neighbour) else {
                return nil
            }
            guard level[neighbour].kind == .submenu else {
                level.swapAt(index, neighbour)
                return parent + [neighbour]
            }
            // Into the submenu next door: at its end when coming from below, else at its start.
            let entry = level.remove(at: index)
            let door = step < 0 ? neighbour : index
            let position = step < 0 ? level[door].children.count : 0
            level[door].children.insert(entry, at: position)
            return parent + [door, position]
        }
        if let moved = inside ?? nil {
            return moved
        }
        // At the edge of a submenu: out of it, right before or right after it.
        guard let door = parent.last else {
            return path
        }
        let outer = Array(parent.dropLast())
        return withChildren(of: outer) { level -> Path in
            guard level.indices.contains(door), level[door].children.indices.contains(index) else {
                return path
            }
            let entry = level[door].children.remove(at: index)
            let position = step < 0 ? door : door + 1
            level.insert(entry, at: position)
            return outer + [position]
        } ?? path
    }

    /// A double click in the editor: adds or removes the hide character at the start of the
    /// title (spec 12 › Hiding entries).
    public mutating func toggleHideMark(at path: Path) {
        guard !hideCharacter.isEmpty else {
            return
        }
        let mark = hideCharacter
        update(at: path) { entry in
            guard entry.kind != .separator else {
                return
            }
            entry.title = entry.title.hasPrefix(mark) ? String(entry.title.dropFirst(mark.count)) : mark + entry.title
        }
    }
}

/// What the command of a hotlist entry asks for (spec 12 › Command and target path).
public enum HotlistAction: Equatable {
    /// `cd <path>`. With `focusingOnIt` (the path ended in `/:`), the parent is shown with the
    /// cursor on the named folder.
    case changeDirectory(path: String, focusingOnIt: Bool)
    /// The name of a command (`cm_…`, `afm_…` or a user command `em_…`), with what followed it as its argument.
    case command(CommandID, CommandArgument)
    case nothing

    public init(_ command: String) {
        let text = command.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            self = .nothing
        } else if ["cm_", "afm_", "em_"].contains(where: text.lowercased().hasPrefix) {
            let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
            let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            self = .command(
                CommandID(rawValue: parts[0]),
                argument.isEmpty ? .nothing : Int(argument).map(CommandArgument.index) ?? .text(argument)
            )
        } else {
            // A bare path is taken as `cd <path>`.
            var path =
                text.lowercased().hasPrefix("cd ")
                ? String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces) : text
            // A quoted path is the path as it stands: spaces at its ends and a final `:` are its own.
            var isQuoted = false
            if path.count > 1, path.hasPrefix("\""), path.hasSuffix("\"") {
                path = String(path.dropFirst().dropLast())
                isQuoted = true
            }
            if !isQuoted, let suffix = ["//:", "/:", "\\\\:", "\\:"].first(where: path.hasSuffix),
                path.count > suffix.count
            {
                self = .changeDirectory(path: String(path.dropLast(suffix.count)), focusingOnIt: true)
            } else {
                self = .changeDirectory(path: path, focusingOnIt: false)
            }
        }
    }

    /// The command that changes to `path`: `cd <path>`, with the path in quotes when it would be
    /// read differently as it stands (spaces at its ends, a final colon, quotes around it).
    public static func changeDirectoryCommand(to path: String) -> String {
        let edge = { (character: Character?) in character.map { $0.isWhitespace || $0 == ":" || $0 == "\"" } ?? false }
        let needsQuotes = edge(path.first) || edge(path.last)
        return "cd " + (needsQuotes ? "\"" + path + "\"" : path)
    }

    /// The path of a target-path field, which may be written plain or as `cd path`.
    public static func targetPath(_ text: String) -> String? {
        guard case .changeDirectory(let path, _) = Self(text), !path.isEmpty else {
            return nil
        }
        return path
    }
}

/// The hotlist as the Ctrl+D pop-up shows one level of it: the visible entries, then the two
/// fixed items (spec 12 › The hotlist menu).
public struct HotlistMenu {
    public enum Action: Equatable {
        case run(HotlistEntry)
        /// A submenu: its entries are shown next.
        case open(Hotlist.Path)
        /// The Mac's standard folders, shown as a submenu of their own.
        case openFavorites
        case separator
        case addCurrent
        /// The current directory is listed on this level; choosing the item removes it.
        case removeCurrent(Hotlist.Path)
        case configure
    }

    public struct Row: Equatable {
        public let title: String
        public let action: Action
    }

    internal static let separatorTitle = "────────────"

    public let rows: [Row]
    /// The row the list opens on: the entry of the current directory, or the first.
    public let selected: Int

    public var titles: [String] { rows.map(\.title) }

    /// One level of the user's list. `isCurrent` tells whether an entry leads to the directory
    /// the panel shows; such entries, and the submenus holding one, are marked.
    public init(
        _ hotlist: Hotlist,
        at path: Hotlist.Path = [],
        offersFavorites: Bool = false,
        isCurrent: (HotlistEntry) -> Bool
    ) {
        var rows: [Row] = []
        var current: Hotlist.Path?
        var selected: Int?
        for (index, entry) in hotlist.children(of: path).enumerated() where !hotlist.isHidden(entry) {
            let marked = Hotlist.contains(entry) { $0.kind == .item && isCurrent($0) }
            if marked, selected == nil { selected = rows.count }
            switch entry.kind {
            case .separator:
                rows.append(Row(title: Self.separatorTitle, action: .separator))

            case .submenu:
                rows.append(
                    Row(title: Self.mark(marked) + entry.displayTitle + "  ▸", action: .open(path + [index]))
                )

            case .item:
                if marked, current == nil { current = path + [index] }
                rows.append(Row(title: Self.mark(marked) + entry.displayTitle, action: .run(entry)))
            }
        }
        if !rows.isEmpty { rows.append(Row(title: Self.separatorTitle, action: .separator)) }
        if offersFavorites, path.isEmpty {
            rows.append(Row(title: Self.mark(false) + "Favorites  ▸", action: .openFavorites))
        }
        rows.append(
            current.map { Row(title: "− Remove current dir", action: .removeCurrent($0)) }
                ?? Row(title: "+ Add current dir", action: .addCurrent)
        )
        rows.append(Row(title: "* Configure…", action: .configure))
        self.rows = rows
        self.selected = selected ?? 0
    }

    /// A fixed list of places without the editing items (the Mac's Favorites).
    public init(places: [HotlistEntry], isCurrent: (HotlistEntry) -> Bool) {
        rows = places.map { Row(title: Self.mark(isCurrent($0)) + $0.displayTitle, action: .run($0)) }
        selected = places.firstIndex(where: isCurrent) ?? 0
    }

    private static func mark(_ isCurrent: Bool) -> String { isCurrent ? "✓ " : "    " }
}

/// The places a Finder sidebar starts with, offered next to the user's own entries.
public enum MacFavorites {
    /// Works on paths alone; nothing is asked of the disk.
    public static func entries(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [HotlistEntry] {
        let below = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"]
            .map { name in
                HotlistEntry.item(name, command: "cd " + home.appendingPathComponent(name, isDirectory: true).path)
            }
        return [.item("Home", command: "cd " + home.path), .item("Applications", command: "cd /Applications")] + below
            + [
                .item(
                    "iCloud Drive",
                    command: "cd "
                        + home.appendingPathComponent(
                            "Library/Mobile Documents/com~apple~CloudDocs",
                            isDirectory: true
                        )
                        .path
                )
            ]
    }
}
