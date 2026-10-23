import AFMKernel
import Foundation

/// Select group and Unselect group, by a mask or a saved selection type, and the types themselves.
extension Selections {
    /// The help under the mask field of Select group and Define selection.
    internal static let maskHelp =
        "Specify file type, e.g. *.txt, or RegEx with leading '<', like <(a|b). "
        + "Masks after | are left out: *.*|*.bak. >name uses a saved selection type."

    /// The fields of Define selection, filled in from `type`.
    private static func fields(of type: SelectionType) -> [FormField] {
        [
            .text("name", "Name:", type.name),
            .text("mask", "File mask:", type.mask),
            .choice(
                "kind",
                "Applies to:",
                ["Files and folders", "Files only", "Folders only"],
                selected: type.kind.rawValue
            ),
            .text("minSize", "Size at least (e.g. 10k, 1.5M):", SelectionType.text(ofSize: type.minSize)),
            .text("maxSize", "Size at most:", SelectionType.text(ofSize: type.maxSize)),
            .text("from", "Changed from (yyyy-MM-dd [HH:mm]):", SelectionType.text(ofDate: type.modifiedFrom)),
            .text("to", "Changed to:", SelectionType.text(ofDate: type.modifiedTo)),
            .text("days", "Not older than (days):", type.notOlderThanDays.map(String.init) ?? ""),
            .choice("hidden", "Hidden:", ["Any", "Only hidden", "Not hidden"], selected: type.hidden.rawValue),
            .choice("links", "Symbolic links:", ["Any", "Only links", "No links"], selected: type.links.rawValue)
        ]
    }

    /// The type the answer of Define selection describes.
    ///
    /// An empty field is no condition; the text of a field that cannot be read, or of a mask that
    /// cannot be, is added to `unreadable`.
    private static func type(named name: String, from answer: FormValues, unreadable: inout [String]) -> SelectionType {
        func read<Value>(_ key: String, _ parse: (String) -> Value?) -> Value? {
            let text = answer.text(key).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else {
                return nil
            }
            let value = parse(text)
            if value == nil { unreadable.append(text) }
            return value
        }
        let mask = answer.text("mask").trimmingCharacters(in: .whitespaces)
        var saved = SelectionType(name: name, mask: mask.isEmpty ? "*.*" : mask)
        saved.kind = SelectionType.Kind(rawValue: answer.index("kind")) ?? .any
        saved.minSize = read("minSize") { SelectionType.size(from: $0) }
        saved.maxSize = read("maxSize") { SelectionType.size(from: $0) }
        saved.modifiedFrom = read("from") { SelectionType.date(from: $0, endOfDay: false) }
        saved.modifiedTo = read("to") { SelectionType.date(from: $0, endOfDay: true) }
        saved.notOlderThanDays = read("days") { Int($0).flatMap { $0 >= 0 ? $0 : nil } }
        saved.hidden = SelectionType.Tri(rawValue: answer.index("hidden")) ?? .any
        saved.links = SelectionType.Tri(rawValue: answer.index("links")) ?? .any
        if !SelectionMask(saved.mask).isValid { unreadable.append(saved.mask) }
        return saved
    }

    /// Select group / Unselect group (spec 03 › Select and unselect group): asks for a mask,
    /// or takes it from `.text` (the `SELECTFILES` way).
    internal func group(select: Bool, scope: SelectionScope, proposal: String, argument: CommandArgument) {
        if let mask = argument.text {
            apply(mask, select: select, scope: scope)
            return
        }
        guard
            let mask = interaction.prompt(
                select ? "Expand selection" : "Shrink selection",
                value: proposal,
                detail: Self.maskHelp
            )
        else { return }
        apply(mask, select: select, scope: scope)
    }

    /// Selects or unselects what a mask, or a selection type written `>name`, matches.
    internal func apply(_ text: String, select: Bool, scope: SelectionScope) {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else {
            return
        }
        let rule: SelectionRule
        if typed.hasPrefix(">") {
            let name = String(typed.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard let type = store.type(named: name) else {
                interaction.inform("There is no selection type called \(name).", detail: "", style: .warning)
                return
            }
            rule = SelectionRule(type)
        } else {
            rule = SelectionRule(mask: typed)
            store.remember(typed)
        }
        guard rule.mask.isValid else {
            interaction.inform("The regular expression cannot be read.", detail: rule.mask.text, style: .warning)
            return
        }
        let model = source
        let base = model.directory
        let change: PanelModel.SelectionChange = select ? .add : .remove
        // `A>B` pairs files of the same folder: that is worked out over the whole list, in order.
        let now = Date()
        guard !rule.isPairwise else {
            markFound(model, change) { items, _, flag in
                rule.matchingIndices(among: items, base: base, now: now, scope: scope) { flag.isCancelled }
            }
            return
        }
        let probe = rule.probe(base: base, now: now)
        markMatching(model, change, timedOut: rule.mask) { scope.contains($0) && probe($0) }
    }

    /// The saved selection types and the masks used so far, to select or unselect by, or to
    /// remove from the list (the dialog's lower half and its history in the specification).
    internal func groupFromList() {
        let types = store.types
        let rows = types.map { ">" + $0.name } + store.history
        guard !rows.isEmpty else {
            interaction.inform("There are no saved selection types or earlier masks yet.")
            return
        }
        guard
            let answer = interaction.form(
                "Select group",
                detail: "Predefined selection types (>name) and the masks used so far:",
                fields: [.list("row", "", rows)],
                buttons: ["Select", "Unselect", "Remove"]
            )
        else { return }
        let row = answer.index("row")
        guard rows.indices.contains(row) else {
            return
        }
        switch answer.button {
        case 2:
            if row < types.count { store.removeType(named: types[row].name) } else { store.forget(mask: rows[row]) }

        case 1:
            apply(rows[row], select: false, scope: .both)

        default:
            apply(rows[row], select: true, scope: configured)
        }
    }

    /// Define selection (spec 03 › Select and unselect group, *Define...*): creates, changes
    /// or deletes a predefined selection type.
    internal func defineType() {
        let types = store.types
        var type = SelectionType(name: "")
        if !types.isEmpty {
            guard
                let row = interaction.pickRow(
                    "Define selection",
                    rows: ["New selection type"] + types.map(\.name),
                    detail: "Choose the selection type to change:",
                    button: "Edit"
                )
            else { return }
            if row > 0 { type = types[row - 1] }
        }
        guard
            let answer = interaction.form(
                "Define selection",
                detail: Self.maskHelp,
                fields: Self.fields(of: type),
                buttons: ["Save", "Delete"]
            )
        else { return }
        let name = answer.text("name").trimmingCharacters(in: .whitespaces)
        if answer.button == 1 {
            store.removeType(named: name.isEmpty ? type.name : name)
            return
        }
        guard !name.isEmpty else {
            interaction.inform("A selection type needs a name.", detail: "", style: .warning)
            return
        }
        var unreadable: [String] = []
        let saved = Self.type(named: name, from: answer, unreadable: &unreadable)
        guard unreadable.isEmpty else {
            interaction.inform(
                "The selection type was not saved.",
                detail: "Cannot read: " + unreadable.joined(separator: ", "),
                style: .warning
            )
            return
        }
        store.save(saved)
    }
}
