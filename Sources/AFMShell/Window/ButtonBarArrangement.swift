import AFMKernel

/// The button bar as the user rearranges it: lines of groups of buttons. Within a line a
/// separator stands between two groups; a line break (`ToolbarRegistry.lineBreak`) starts the
/// next line. Moving a button, moving a group and removing a button are done here, apart from
/// the view, so that no group and no line is ever left empty and no separator or line break
/// stands at an end or next to another one.
struct ButtonBarArrangement: Equatable {
    /// Where a group goes: into line `line` before its group `at` (`at` may be the line's
    /// count of groups: at its end), or as a line of its own before line `at` (`at` may be
    /// the count of lines: below the last).
    enum Place: Equatable {
        case line(Int, at: Int)
        case newLine(at: Int)
    }

    /// Where a dragged button goes: into a group before its button `at` (`at` may be the
    /// group's count: at its end), or on its own as a new group.
    enum Target: Equatable {
        case inGroup(line: Int, group: Int, at: Int)
        case newGroup(Place)
    }

    private(set) var lines: [[[CommandID]]]

    init(entries: [CommandID?]) {
        var lines: [[[CommandID]]] = [[[]]]
        for entry in entries {
            switch entry {
            case nil: lines[lines.count - 1].append([])
            case ToolbarRegistry.lineBreak: lines.append([[]])
            case let command?: lines[lines.count - 1][lines[lines.count - 1].count - 1].append(command)
            }
        }
        self.lines = lines
        compact()
    }

    /// The bar in the form the toolbar registry keeps: nil is a separator.
    var entries: [CommandID?] {
        lines.enumerated().flatMap { number, line -> [CommandID?] in
            let groups = line.enumerated().flatMap { index, group in
                (index == 0 ? [] : [nil]) + group.map(Optional.init)
            }
            return (number == 0 ? [] : [ToolbarRegistry.lineBreak]) + groups
        }
    }

    // Each change marks what it takes away (an empty group stands for a moved one), puts it
    // in at its new place while every index is still the one the caller meant, and only then
    // sweeps the marks and whatever was left empty away.

    mutating func moveButton(line: Int, group: Int, index: Int, to target: Target) {
        guard let command = button(line: line, group: group, index: index) else { return }
        var marked = lines.map { $0.map { $0.map(Optional.init) } }
        marked[line][group][index] = nil
        switch target {
        case .inGroup(let toLine, let toGroup, let at):
            guard marked.indices.contains(toLine), marked[toLine].indices.contains(toGroup),
                (0...marked[toLine][toGroup].count).contains(at)
            else { return }
            marked[toLine][toGroup].insert(command, at: at)

        case .newGroup(let place):
            guard Self.insert([command], at: place, into: &marked) else { return }
        }
        lines = marked.map { $0.map { $0.compactMap { $0 } } }
        compact()
    }

    mutating func moveGroup(line: Int, group: Int, to place: Place) {
        guard lines.indices.contains(line), lines[line].indices.contains(group) else { return }
        var marked = lines.map { $0.map { $0.map(Optional.init) } }
        let moved = lines[line][group]
        marked[line][group] = []
        guard Self.insert(moved, at: place, into: &marked) else { return }
        lines = marked.map { $0.map { $0.compactMap { $0 } } }
        compact()
    }

    mutating func removeButton(line: Int, group: Int, index: Int) {
        guard button(line: line, group: group, index: index) != nil else { return }
        lines[line][group].remove(at: index)
        compact()
    }

    private func button(line: Int, group: Int, index: Int) -> CommandID? {
        guard lines.indices.contains(line), lines[line].indices.contains(group),
            lines[line][group].indices.contains(index)
        else { return nil }
        return lines[line][group][index]
    }

    private static func insert(_ group: [CommandID], at place: Place, into lines: inout [[[CommandID?]]]) -> Bool {
        switch place {
        case .line(let line, let at):
            guard lines.indices.contains(line), (0...lines[line].count).contains(at) else { return false }
            lines[line].insert(group.map(Optional.init), at: at)

        case .newLine(let at):
            guard (0...lines.count).contains(at) else { return false }
            lines.insert([group.map(Optional.init)], at: at)
        }
        return true
    }

    private mutating func compact() {
        lines = lines.map { $0.filter { !$0.isEmpty } }.filter { !$0.isEmpty }
    }
}
