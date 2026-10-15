import AFMKernel

/// The button bar as the user rearranges it: lines of groups of buttons.
///
/// Within a line a separator stands between two groups; a line break
/// (`ToolbarRegistry.lineBreak`) starts the next line. Moving a button, moving a group and
/// removing a button are done here, apart from the view, so that no group and no line is ever
/// left empty and no separator or line break stands at an end or next to another one.
internal struct ButtonBarArrangement: Equatable {
    /// Where a group goes.
    internal enum Place: Equatable {
        /// Into line `line` before its group `beforeGroup`, which may be the line's count of
        /// groups: at its end.
        case line(Int, beforeGroup: Int)
        /// As a line of its own before line `beforeLine`, which may be the count of lines:
        /// below the last.
        case newLine(beforeLine: Int)
    }

    /// Where a dragged button goes.
    internal enum Target: Equatable {
        /// Into a group before its button `beforeButton`, which may be the group's count: at
        /// its end.
        case inGroup(line: Int, group: Int, beforeButton: Int)
        /// On its own, as a new group.
        case newGroup(Place)
    }

    /// The lines, each a list of groups, each a list of buttons.
    internal private(set) var lines: [[[CommandID]]]

    /// The bar in the form the toolbar registry keeps: nil is a separator.
    internal var entries: [CommandID?] {
        lines.enumerated()
            .flatMap { number, line -> [CommandID?] in
                let groups = line.enumerated()
                    .flatMap { index, group in
                        (index == 0 ? [] : [nil]) + group.map(Optional.init)
                    }
                return (number == 0 ? [] : [ToolbarRegistry.lineBreak]) + groups
            }
    }

    /// The arrangement of the bar the registry keeps as `entries`, with empty groups and lines
    /// left out.
    internal init(entries: [CommandID?]) {
        var parsed: [[[CommandID]]] = [[[]]]
        for entry in entries {
            switch entry {
            case nil:
                parsed[parsed.count - 1].append([])

            case ToolbarRegistry.lineBreak:
                parsed.append([[]])

            case let command?:
                parsed[parsed.count - 1][parsed[parsed.count - 1].count - 1].append(command)
            }
        }
        lines = parsed
        compact()
    }

    // Each change marks what it takes away (an empty group stands for a moved one), puts it
    // in at its new place while every index is still the one the caller meant, and only then
    // sweeps the marks and whatever was left empty away.

    /// Puts `group` in at `place` of `lines`; false when there is no such place.
    private static func insert(_ group: [CommandID], at place: Place, into lines: inout [[[CommandID?]]]) -> Bool {
        switch place {
        case .line(let line, let before):
            guard lines.indices.contains(line), (0...lines[line].count).contains(before) else {
                return false
            }
            lines[line].insert(group.map(Optional.init), at: before)

        case .newLine(let before):
            guard (0...lines.count).contains(before) else {
                return false
            }
            lines.insert([group.map(Optional.init)], at: before)
        }
        return true
    }

    /// Moves a button to `target`; nothing changes when either is not there.
    internal mutating func moveButton(line: Int, group: Int, index: Int, to target: Target) {
        guard let command = button(line: line, group: group, index: index) else {
            return
        }
        var marked = lines.map { $0.map { $0.map(Optional.init) } }
        marked[line][group][index] = nil
        switch target {
        case .inGroup(let toLine, let toGroup, let before):
            guard marked.indices.contains(toLine), marked[toLine].indices.contains(toGroup),
                (0...marked[toLine][toGroup].count).contains(before)
            else {
                return
            }
            marked[toLine][toGroup].insert(command, at: before)

        case .newGroup(let place):
            guard Self.insert([command], at: place, into: &marked) else {
                return
            }
        }
        lines = marked.map { $0.map { $0.compactMap(\.self) } }
        compact()
    }

    /// Moves a group to `place`; nothing changes when either is not there.
    internal mutating func moveGroup(line: Int, group: Int, to place: Place) {
        guard lines.indices.contains(line), lines[line].indices.contains(group) else {
            return
        }
        var marked = lines.map { $0.map { $0.map(Optional.init) } }
        let moved = lines[line][group]
        marked[line][group] = []
        guard Self.insert(moved, at: place, into: &marked) else {
            return
        }
        lines = marked.map { $0.map { $0.compactMap(\.self) } }
        compact()
    }

    /// Takes a button off the bar; nothing changes when it is not there.
    internal mutating func removeButton(line: Int, group: Int, index: Int) {
        guard button(line: line, group: group, index: index) != nil else {
            return
        }
        lines[line][group].remove(at: index)
        compact()
    }

    /// The button at a place; nil when there is none.
    private func button(line: Int, group: Int, index: Int) -> CommandID? {
        guard lines.indices.contains(line), lines[line].indices.contains(group),
            lines[line][group].indices.contains(index)
        else {
            return nil
        }
        return lines[line][group][index]
    }

    /// Leaves out empty groups and empty lines.
    private mutating func compact() {
        lines = lines.map { $0.filter { !$0.isEmpty } }.filter { !$0.isEmpty }
    }
}
