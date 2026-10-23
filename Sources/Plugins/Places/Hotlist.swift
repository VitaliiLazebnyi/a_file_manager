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
        /// Where the entry is in the list.
        public let path: Path
        /// The entry itself.
        public let entry: HotlistEntry
        /// How deep the entry is in submenus: 0 on the top level.
        public var depth: Int { path.count - 1 }
    }

    /// The most entries the list takes (spec 12 › Storage and limits).
    public static let limit = 2_000

    /// The entries of the top level, in display order.
    public var entries: [HotlistEntry]
    /// Entries whose title starts with this are hidden while `hidesMarked` is on.
    public var hideCharacter: String
    /// Whether entries marked with `hideCharacter` are hidden from the Ctrl+D menu.
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

    /// How many entries the list holds, with everything inside its submenus.
    public var count: Int { rows.count }

    /// A list of `entries` with the given hiding settings.
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

    /// How many entries `entry` counts as: itself and everything inside it.
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

    /// The entry at `path`; nil when there is none.
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
            while position > 0, level[position - 1].kind == .submenu {
                position -= 1
            }
        }
        return insert(entry, at: parent + [position])
    }

    /// Takes the entry at `path` out of the list, with everything inside it.
    ///
    /// Returns the entry; nil when there is none.
    @discardableResult
    public mutating func remove(at path: Path) -> HotlistEntry? {
        guard let index = path.last else {
            return nil
        }
        let removed = withChildren(of: Array(path.dropLast())) { level in
            level.indices.contains(index) ? level.remove(at: index) : nil
        }
        // Nil when the level does not exist; the entry, or nil again, when it does.
        guard let entry = removed else {
            return nil
        }
        return entry
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
        if let found = inside, let moved = found {
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
