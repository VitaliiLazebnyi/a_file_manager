import AFMContracts
import AFMKernel
import AppKit

/// The Mark menu (spec 03 › Selection, 09 › Compare directories and Mark newer). The commands
/// change the model's selection; the panel redraws by itself.
public final class SelectionPlugin: Plugin {
    public let name = "Selection"
    private let pasteboard: NSPasteboard
    private let background: Bool
    private var selections: Selections?

    /// Tests pass a pasteboard of their own, so they leave the user's clipboard alone. With
    /// `background` false everything is worked out on the calling thread and has taken effect
    /// when a command returns; otherwise the commands that can take long (a regular expression,
    /// a long list, comparing two folders, the clipboard) work off the main thread and the
    /// selection changes when they are done.
    public init(pasteboard: NSPasteboard = .general, background: Bool = true) {
        self.pasteboard = pasteboard
        self.background = background
    }

    public func start(in kernel: Kernel) {
        let selections = Selections(kernel, pasteboard: pasteboard, background: background)
        self.selections = selections
        let commands = kernel.commands
        let model = { kernel.panels.source.model }
        // While a directory is still arriving, "all" would silently mean "all so far".
        let isComplete = { model().isComplete }
        let hasCursorItem = { isComplete() && model().cursorItem != nil }
        let bothComplete = { kernel.panels.all.allSatisfy { $0.model.isComplete } }
        typealias Ids = SelectionCommands
        func key(_ key: Key, _ modifiers: KeyModifiers = []) -> [Shortcut] { [Shortcut(key, modifiers)] }

        // Select group and Unselect group. `.text` gives the mask and skips the dialog.
        let groups: [(CommandID, String, [Shortcut], Bool, () -> SelectionScope)] = [
            (.selectGroup, "Select Group…", [.cmd("="), Shortcut(.keypadPlus)], true, { selections.configured }),
            (.unselectGroup, "Unselect Group…", [.cmd("-"), Shortcut(.keypadMinus)], false, { .both }),
            (Ids.selectBoth, "Select Group: Files and Folders…", [], true, { .both }),
            (Ids.selectFiles, "Select Group: Files Only…", [], true, { .files }),
            (Ids.selectFolders, "Select Group: Folders Only…", [], true, { .folders }),
            (Ids.selectGroupOtherChoice, "Select Group: Other Choice of Folders…", key(.keypadPlus, .shift), true, { selections.other }),
            (Ids.clearFiles, "Unselect Group: Files Only…", key(.keypadMinus, .shift), false, { .files }),
            (Ids.clearFolders, "Unselect Group: Folders Only…", [], false, { .folders }),
            (Ids.clearAsConfigured, "Unselect Group: As Configured…", [], false, { selections.configured }),
        ]
        for (id, title, shortcuts, select, scope) in groups {
            commands.register(Command(id, title, shortcuts), enabled: isComplete, parameterized: { argument in
                selections.group(select: select, scope: scope(), argument: argument)
            })
        }
        commands.register(Command(Ids.selectGroupCurrentExtension, "Select Group with Current Extension…"), enabled: isComplete) {
            let ext = model().cursorFile?.ext ?? ""
            selections.group(select: true, scope: selections.configured, proposal: ext.isEmpty ? "*.*" : "*." + ext, argument: .none)
        }
        commands.register(Command(Ids.selectFromList, "Select Group from List…"), enabled: isComplete, selections.groupFromList)
        commands.register(Command(Ids.defineSelectionType, "Define Selection Type…", runsDuringJobs: true), selections.defineType)

        // Select all, Unselect all. `.index` n takes every n-th line from the cursor.
        // Unselecting everything is always safe, also while a directory is still arriving.
        let alls: [(CommandID, String, [Shortcut], Bool, EditingRole?, () -> SelectionScope)] = [
            (.selectAll, "Select All", [.cmd("a"), Shortcut(.keypadPlus, .control)], true, .selectAll, { selections.configured }),
            (.unselectAll, "Unselect All", [.cmd("a", .shift), Shortcut(.keypadMinus, .control)], false, nil, { .both }),
            (Ids.selectAllBoth, "Select All Files and Folders", [], true, nil, { .both }),
            (Ids.selectAllFiles, "Select All Files", [], true, nil, { .files }),
            (Ids.selectAllFolders, "Select All Folders", [], true, nil, { .folders }),
            (Ids.selectAllOtherChoice, "Select All: Other Choice of Folders", key(.keypadPlus, [.control, .shift]), true, nil, { selections.other }),
            (Ids.clearAllFiles, "Unselect All Files", key(.keypadMinus, [.control, .shift]), false, nil, { .files }),
            (Ids.clearAllFolders, "Unselect All Folders", [], false, nil, { .folders }),
            (Ids.clearAllAsConfigured, "Unselect All: As Configured", [], false, nil, { selections.configured }),
        ]
        for (id, title, shortcuts, select, role, scope) in alls {
            commands.register(Command(id, title, shortcuts, editingRole: role), enabled: { !select || isComplete() }, parameterized: { argument in
                selections.all(select: select, scope: scope(), step: argument.index ?? 0)
            })
        }

        let inversions: [(CommandID, String, [Shortcut], () -> SelectionScope)] = [
            (.invertSelection, "Invert Selection", key(.keypadMultiply), { selections.configured }),
            (Ids.invertBoth, "Invert Selection: Files and Folders", [], { .both }),
            (Ids.invertFiles, "Invert Selection: Files Only", [], { .files }),
            (Ids.invertFolders, "Invert Selection: Folders Only", [], { .folders }),
            (Ids.invertOtherChoice, "Invert Selection: Other Choice of Folders", key(.keypadMultiply, .shift), { selections.other }),
        ]
        for (id, title, shortcuts, scope) in inversions {
            commands.register(Command(id, title, shortcuts), enabled: isComplete) { selections.invert(scope: scope()) }
        }

        // By the item under the cursor.
        let similar: [(CommandID, String, [Shortcut], Selections.Similarity, Bool)] = [
            (Ids.selectCurrentExtension, "Select All With Same Extension", key(.keypadPlus, .option), .ext, true),
            (Ids.unselectCurrentExtension, "Unselect All With Same Extension", key(.keypadMinus, .option), .ext, false),
            (Ids.selectCurrentName, "Select All With Same Name", [], .name, true),
            (Ids.unselectCurrentName, "Unselect All With Same Name", [], .name, false),
            (Ids.selectCurrentNameAndExtension, "Select All With Same Name and Extension", [], .nameAndExt, true),
            (Ids.unselectCurrentNameAndExtension, "Unselect All With Same Name and Extension", [], .nameAndExt, false),
            (Ids.selectCurrentPath, "Select All in Same Folder", [], .path, true),
            (Ids.unselectCurrentPath, "Unselect All in Same Folder", [], .path, false),
        ]
        for (id, title, shortcuts, similarity, select) in similar {
            commands.register(Command(id, title, shortcuts), enabled: hasCursorItem) { selections.similar(to: similarity, select: select) }
        }
        commands.register(Command(Ids.select, "Select and Go to Next"), parameterized: { selections.step(select: true, count: $0.index ?? 1) })
        commands.register(Command(Ids.unselect, "Unselect and Go to Next"), parameterized: { selections.step(select: false, count: $0.index ?? 1) })

        // Saving and loading.
        commands.register(Command(Ids.saveSelection, "Save Selection")) { model().saveSelection() }
        commands.register(Command(.restoreSelection, "Restore Selection", [.cmd("i", .shift), Shortcut(.keypadDivide)]), selections.restore)
        let hasOperands = { model().hasOperands }
        let saves: [(CommandID, String, SelectionFile.Encoding)] = [
            (Ids.saveSelectionToFile, "Save Selection to File…", .unicode),
            (Ids.saveSelectionToFileUnicode, "Save Selection to File (Unicode)…", .unicode),
            (Ids.saveSelectionToFileANSI, "Save Selection to File (ANSI)…", .ansi),
        ]
        for (id, title, encoding) in saves {
            commands.register(Command(id, title), enabled: hasOperands, parameterized: { selections.saveToFile(encoding, argument: $0) })
        }
        commands.register(Command(Ids.loadSelectionFromFile, "Load Selection from File…"), enabled: isComplete,
                          parameterized: selections.loadFromFile)
        commands.register(Command(Ids.loadSelectionFromClipboard, "Load Selection from Clipboard"), enabled: isComplete,
                          selections.loadFromClipboard)

        // Comparing the two panels.
        commands.register(Command(Ids.compareDirectories, "Compare Directories", [.f(2, .shift)]), enabled: bothComplete, parameterized: {
            selections.compare(mode: DirectoryComparison.Mode(rawValue: $0.index ?? 0) ?? .newerOrDifferent, withSubdirectories: false)
        })
        commands.register(Command(Ids.compareDirectoriesWithSubdirectories, "Compare Directories, Mark Missing Folders Too"),
                          enabled: bothComplete, parameterized: {
            selections.compare(mode: DirectoryComparison.Mode(rawValue: $0.index ?? 0) ?? .newerOrDifferent, withSubdirectories: true)
        })
        commands.register(Command(Ids.markNewerHideSame, "Mark Newer, Hide Same Files"), enabled: bothComplete,
                          checked: { selections.shows(.comparison, in: model()) }, selections.markNewerHideSame)

        kernel.menus.add([.selectGroup, .unselectGroup, Ids.selectFromList, Ids.defineSelectionType], to: .markGroups)
        kernel.menus.add([.selectAll, .unselectAll, .invertSelection, Ids.selectCurrentExtension], to: .markAll)
        kernel.menus.add([Ids.saveSelection, .restoreSelection, Ids.saveSelectionToFile, Ids.loadSelectionFromFile,
                          Ids.loadSelectionFromClipboard], to: .markStore)
        kernel.menus.add([Ids.compareDirectories, Ids.compareDirectoriesWithSubdirectories, Ids.markNewerHideSame], to: .markCompare)

        kernel.toolbar.add(.selectGroup, symbol: "plus.square", group: 50)
        kernel.toolbar.add(.unselectGroup, symbol: "minus.square", group: 50)
        kernel.toolbar.add(.invertSelection, symbol: "circle.lefthalf.filled", group: 50)
        kernel.toolbar.add(Ids.compareDirectories, symbol: "rectangle.split.2x1", group: 50)
        kernel.toolbar.setSymbol("checkmark.square", for: .selectAll)
        kernel.toolbar.setSymbol("square", for: .unselectAll)
        kernel.toolbar.setSymbol("arrow.uturn.backward.square", for: .restoreSelection)
        kernel.toolbar.setSymbol("clock.arrow.2.circlepath", for: Ids.markNewerHideSame)

        kernel.preferences.add(PreferencePage(title: "Selection", preferences: [
            Preference(SelectionStore.marksFoldersKey, "Num +, Ctrl+Num + and Num * also select folders", .flag(default: true)),
            Preference(SelectionStore.oneHourKey, "Compare directories: times exactly one hour apart are equal", .flag(default: false)),
        ]))
    }
}

/// Which entries a selection command affects (spec 03 › Selection, *Selection (with Num +)*).
enum SelectionScope {
    case both, files, folders

    func contains(_ item: FileItem) -> Bool {
        switch self {
        case .both: return true
        case .files: return !item.isFolder
        case .folders: return item.isFolder
        }
    }
}

/// The behaviour behind the Mark commands.
///
/// **Threading.** The commands run on the main thread and change the selection there. What
/// can take long is worked out elsewhere (when `background` is on): a regular expression of a
/// mask always (it can take any time), and the work on a long list, comparing two folders
/// (which asks the volumes) and the clipboard always; the lists are handed over by value and
/// the result is applied on the main thread only if the list is still the one it was made
/// for (`listVersion`). A long selection is applied in pieces, so the window stays alive.
/// Selection files touch a file system: they are written and read inside a job, on the job's
/// thread, through the file system's provider, and the job's completion returns to the main
/// thread to change the selection.
final class Selections {
    enum Similarity {
        case ext, name, nameAndExt, path
    }

    /// A list shown only in part by this plugin.
    enum RestrictedView {
        case comparison
    }

    private struct Restriction {
        weak var model: PanelModel?
        let view: RestrictedView
        let directory: URL
        let title: String
    }

    private let kernel: Kernel
    private let pasteboard: NSPasteboard
    private let store: SelectionStore
    /// The tabs whose lists this plugin has cut down, by the identity of their models.
    private var restrictions: [ObjectIdentifier: Restriction] = [:]
    private var subscription: AnyObject?
    private let background: Bool
    /// The computation under way; a newer command ends it.
    private var running: CancellationFlag?
    /// Lists longer than this are worked on off the main thread.
    static let longList = 20_000
    /// How many names are applied to the model in one piece of main-thread work.
    static let applyPiece = 20_000

    init(_ kernel: Kernel, pasteboard: NSPasteboard, background: Bool = true) {
        self.kernel = kernel
        self.pasteboard = pasteboard
        self.background = background
        store = SelectionStore(settings: kernel.settings)
        // A comparison view belongs to the directory it was made in: it ends when the panel
        // goes elsewhere (spec 09 › Ending the comparison view).
        subscription = kernel.panelEvents.subscribe { [weak self] event, panel in
            if case .locationChanged = event { self?.locationChanged(of: panel.model) }
        }
    }

    private var source: PanelModel { kernel.panels.source.model }
    private var ui: UserInteraction { kernel.ui }

    /// What Num +, Ctrl+Num + and Num * affect, and the choice their Shift variants make.
    var configured: SelectionScope { store.marksFolders ? .both : .files }
    var other: SelectionScope { store.marksFolders ? .files : .both }

    // MARK: Changing a selection

    /// A list as work on it was started, with what tells whether it is still the list the
    /// result belongs to. Taken on the main thread (nothing is copied).
    private struct Frozen {
        let model: PanelModel
        let basis: PanelModel.Basis
        /// Guards indexes of `basis.items`.
        let shownVersion: Int
        let operands: PanelModel.Operands

        init(_ model: PanelModel) {
            self.model = model
            basis = model.basis
            shownVersion = model.shownVersion
            operands = model.operandsSnapshot()
        }

        var items: [FileItem] { basis.items }
    }

    /// How often a result that the list outgrew is worked out again before it is given up.
    static let attempts = 8

    /// Works `work` out and then `apply`s its result on the main thread. Off the main thread
    /// when `heavy` (and background work is on), handing it a flag that ends it when a newer
    /// command has started. `apply` says whether the result still fitted the lists (the
    /// model refuses a result made for a list it no longer has): if not, and the panels still
    /// show the folders they showed, `work` is done again for the lists as they are now.
    private func compute<Result>(heavy: Bool, models: [PanelModel], _ work: @escaping ([Frozen], CancellationFlag) -> Result,
                                 apply: @escaping ([Frozen], Result) -> Bool) {
        let flag = CancellationFlag()
        running?.cancel()
        running = flag
        let directories = models.map(\.directory)
        func attempt(_ number: Int) {
            let frozen = models.map(Frozen.init)
            guard heavy && background else {
                let result = work(frozen, flag)
                _ = apply(frozen, result)
                if running === flag { running = nil }
                return
            }
            // (Some of this work asks a file system: on a thread of the kernel's own.)
            BlockingCalls.run { [weak self] in
                let result = autoreleasepool { work(frozen, flag) }
                // A result can ask the user something (a mask that took too long): from the run loop.
                performOnMainLoop {
                    guard let self else { return }
                    func finish() { if self.running === flag { self.running = nil } }
                    // A newer command, or a panel that went to another folder: the result is of no use.
                    guard !flag.isCancelled, zip(models, directories).allSatisfy({ $0.directory.isSameLocation(as: $1) }) else { return finish() }
                    if apply(frozen, result) { return finish() }
                    guard number < Selections.attempts else {
                        finish()
                        return self.kernel.commands.onRejected()
                    }
                    attempt(number + 1)
                }
            }
        }
        attempt(1)
    }

    /// Marks, unmarks or (with `.replace`) makes the selection of the shown entries that
    /// `matches` holds for. The rows are found on all cores, in the background for a long list,
    /// and the model takes them as one bit set. `matches` looks at the entry alone.
    /// `timedOut` names a mask whose regular expression may have run out of time: nothing is
    /// changed then, and the user is told.
    private func mark(_ model: PanelModel, _ change: PanelModel.SelectionChange, timedOut mask: SelectionMask? = nil,
                      matching matches: @escaping (FileItem) -> Bool) {
        // A regular expression can take long on any list.
        compute(heavy: model.items.count > Selections.longList || mask?.isRegex == true, models: [model], { frozen, _ in
            PanelModel.rows(of: frozen[0].basis, where: matches)
        }, apply: { [weak self] frozen, rows in
            if let mask, mask.timedOut {
                self?.ui.inform("The regular expression takes too long.", detail: mask.text, style: .warning)
                return true
            }
            return frozen[0].model.setSelection(rows, change)
        })
    }

    /// The same for what is found by walking the whole list in order (a step, a mask that
    /// pairs files, the marks of an inversion): `find` returns indexes of the shown items.
    private func mark(_ model: PanelModel, _ change: PanelModel.SelectionChange, timedOut mask: SelectionMask? = nil,
                      indices find: @escaping ([FileItem], PanelModel.Operands, CancellationFlag) -> [Int]) {
        compute(heavy: model.items.count > Selections.longList || mask?.isRegex == true, models: [model], { frozen, flag in
            find(frozen[0].items, frozen[0].operands, flag)
        }, apply: { [weak self] frozen, indices in
            if let mask, mask.timedOut {
                self?.ui.inform("The regular expression takes too long.", detail: mask.text, style: .warning)
                return true
            }
            return Selections.take(indices, change, in: frozen[0])
        })
    }

    private static func take(_ indices: [Int], _ change: PanelModel.SelectionChange, in frozen: Frozen) -> Bool {
        let model = frozen.model
        switch change {
        case .replace:
            if indices.isEmpty && model.selectionCount == 0 { return model.shownVersion == frozen.shownVersion }
            return model.setSelection(indices: indices, shownVersion: frozen.shownVersion)
        case .add: return model.setSelected(true, indices: indices, shownVersion: frozen.shownVersion)
        case .remove: return model.setSelected(false, indices: indices, shownVersion: frozen.shownVersion)
        }
    }

    // MARK: Groups

    static let maskHelp = "Specify file type, e.g. *.txt, or RegEx with leading '<', like <(a|b). "
        + "Masks after | are left out: *.*|*.bak. >name uses a saved selection type."

    /// Select group / Unselect group (spec 03 › Select and unselect group): asks for a mask,
    /// or takes it from `.text` (the `SELECTFILES` way).
    func group(select: Bool, scope: SelectionScope, proposal: String = "*.*", argument: CommandArgument) {
        if let mask = argument.text { return apply(mask, select: select, scope: scope) }
        guard let mask = ui.prompt(select ? "Expand selection" : "Shrink selection", value: proposal, detail: Selections.maskHelp) else { return }
        apply(mask, select: select, scope: scope)
    }

    /// Selects or unselects what a mask, or a selection type written `>name`, matches.
    func apply(_ text: String, select: Bool, scope: SelectionScope) {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let rule: SelectionRule
        if text.hasPrefix(">") {
            let name = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard let type = store.type(named: name) else {
                return ui.inform("There is no selection type called \(name).", detail: "", style: .warning)
            }
            rule = SelectionRule(type)
        } else {
            rule = SelectionRule(mask: text)
            store.remember(text)
        }
        guard rule.mask.isValid else {
            return ui.inform("The regular expression cannot be read.", detail: rule.mask.text, style: .warning)
        }
        let model = source
        let base = model.directory
        let change: PanelModel.SelectionChange = select ? .add : .remove
        // `A>B` pairs files of the same folder: that is worked out over the whole list, in order.
        guard !rule.isPairwise else {
            return mark(model, change, timedOut: rule.mask, indices: { items, _, flag in
                rule.matchingIndices(among: items, base: base, scope: scope, cancelled: { flag.isCancelled })
            })
        }
        let probe = rule.probe(base: base)
        mark(model, change, timedOut: rule.mask, matching: { scope.contains($0) && probe($0) })
    }

    /// The saved selection types and the masks used so far, to select or unselect by, or to
    /// remove from the list (the dialog's lower half and its history in the specification).
    func groupFromList() {
        let types = store.types
        let rows = types.map { ">" + $0.name } + store.history
        guard !rows.isEmpty else { return ui.inform("There are no saved selection types or earlier masks yet.") }
        guard let answer = ui.form("Select group", detail: "Predefined selection types (>name) and the masks used so far:",
                                   fields: [.list("row", "", rows)], buttons: ["Select", "Unselect", "Remove"]) else { return }
        let row = answer.index("row")
        guard rows.indices.contains(row) else { return }
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
    func defineType() {
        let types = store.types
        var type = SelectionType(name: "")
        if !types.isEmpty {
            guard let row = ui.pickRow("Define selection", detail: "Choose the selection type to change:",
                                       rows: ["New selection type"] + types.map(\.name), button: "Edit") else { return }
            if row > 0 { type = types[row - 1] }
        }
        let fields: [FormField] = [
            .text("name", "Name:", type.name),
            .text("mask", "File mask:", type.mask),
            .choice("kind", "Applies to:", ["Files and folders", "Files only", "Folders only"], selected: type.kind.rawValue),
            .text("minSize", "Size at least (e.g. 10k, 1.5M):", SelectionType.text(ofSize: type.minSize)),
            .text("maxSize", "Size at most:", SelectionType.text(ofSize: type.maxSize)),
            .text("from", "Changed from (yyyy-MM-dd [HH:mm]):", SelectionType.text(ofDate: type.modifiedFrom)),
            .text("to", "Changed to:", SelectionType.text(ofDate: type.modifiedTo)),
            .text("days", "Not older than (days):", type.notOlderThanDays.map(String.init) ?? ""),
            .choice("hidden", "Hidden:", ["Any", "Only hidden", "Not hidden"], selected: type.hidden.rawValue),
            .choice("links", "Symbolic links:", ["Any", "Only links", "No links"], selected: type.links.rawValue),
        ]
        guard let answer = ui.form("Define selection", detail: Selections.maskHelp, fields: fields, buttons: ["Save", "Delete"]) else { return }
        let name = answer.text("name").trimmingCharacters(in: .whitespaces)
        if answer.button == 1 { return store.removeType(named: name.isEmpty ? type.name : name) }
        guard !name.isEmpty else { return ui.inform("A selection type needs a name.", detail: "", style: .warning) }

        /// An empty field is no condition; a field that cannot be read stops the saving.
        var unreadable: [String] = []
        func read<Value>(_ key: String, _ parse: (String) -> Value?) -> Value? {
            let text = answer.text(key).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            let value = parse(text)
            if value == nil { unreadable.append(text) }
            return value
        }
        let mask = answer.text("mask").trimmingCharacters(in: .whitespaces)
        var saved = SelectionType(name: name, mask: mask.isEmpty ? "*.*" : mask)
        saved.kind = SelectionType.Kind(rawValue: answer.index("kind")) ?? .any
        saved.minSize = read("minSize") { SelectionType.size(from: $0) }
        saved.maxSize = read("maxSize") { SelectionType.size(from: $0) }
        saved.modifiedFrom = read("from") { SelectionType.date(from: $0) }
        saved.modifiedTo = read("to") { SelectionType.date(from: $0, endOfDay: true) }
        saved.notOlderThanDays = read("days") { Int($0).flatMap { $0 >= 0 ? $0 : nil } }
        saved.hidden = SelectionType.Tri(rawValue: answer.index("hidden")) ?? .any
        saved.links = SelectionType.Tri(rawValue: answer.index("links")) ?? .any
        if !SelectionMask(saved.mask).isValid { unreadable.append(saved.mask) }
        guard unreadable.isEmpty else {
            return ui.inform("The selection type was not saved.", detail: "Cannot read: " + unreadable.joined(separator: ", "), style: .warning)
        }
        store.save(saved)
    }

    // MARK: All, invert, similar, step

    /// `step` 0 means every entry; n ≥ 1 every n-th line downward from the cursor, and
    /// n ≤ -1 upward (spec 17 › Commands with parameters).
    func all(select: Bool, scope: SelectionScope, step: Int) {
        let model = source
        let change: PanelModel.SelectionChange = select ? .add : .remove
        guard step != 0 else {
            if scope == .both { return select ? model.selectAll() : model.clearSelection() }
            return mark(model, change, matching: scope.contains)
        }
        // A step beyond the list is the same as the list's length.
        let step = max(-Int(Int32.max), min(step, Int(Int32.max)))
        let cursor = model.cursor - (model.hasParentRow ? 1 : 0)
        mark(model, change, indices: { items, _, _ in
            var picked: [Int] = []
            var seen = 0
            let every = abs(step)
            func visit(_ index: Int) {
                guard scope.contains(items[index]) else { return }
                if seen % every == 0 { picked.append(index) }
                seen += 1
            }
            if step > 0 {
                var index = max(cursor, 0)
                while index < items.count { visit(index); index += 1 }
            } else {
                var index = min(cursor, items.count - 1)
                while index >= 0 { visit(index); index -= 1 }
            }
            return picked
        })
    }

    func invert(scope: SelectionScope) {
        let model = source
        // Inverting everything is a pass over bits.
        if scope == .both { return model.invertSelection() }
        // The entries of the scope change their mark and the others keep theirs.
        mark(model, .replace, indices: { items, marks, _ in
            var indices: [Int] = []
            for index in items.indices where scope.contains(items[index]) != marks.isMarked(at: index) { indices.append(index) }
            return indices
        })
    }

    /// Restore Selection: the saved marks that are still shown become the selection (a pass
    /// over bits in the model).
    func restore() {
        source.restoreSelection()
    }

    /// Selects or unselects everything that is like the item under the cursor. The same
    /// extension is asked of files only; the same folder matters where a list gathers
    /// entries of several folders (a branch view, a search result).
    func similar(to similarity: Similarity, select: Bool) {
        let model = source
        guard let cursor = model.cursorItem else { return }
        func same(_ first: String, _ second: String) -> Bool { first.caseInsensitiveCompare(second) == .orderedSame }
        let folder = similarity == .path ? cursor.url.deletingLastPathComponent().locationKey : ""
        mark(model, select ? .add : .remove, matching: { item in
            switch similarity {
            case .ext: return !item.isFolder && !cursor.isFolder && same(item.ext, cursor.ext)
            case .name: return same(item.baseName, cursor.baseName)
            case .nameAndExt: return same(item.name, cursor.name)
            case .path: return item.url.deletingLastPathComponent().locationKey == folder
            }
        })
    }

    /// Selects or unselects `count` items from the cursor on and moves the cursor past them;
    /// a negative count works upward.
    func step(select: Bool, count: Int) {
        let model = source
        guard count != 0, model.rowCount > 0 else { return }
        // A count beyond the list is the length of the list; the sum cannot overflow then.
        let count = max(-model.rowCount, min(count, model.rowCount))
        let last = max(0, min(model.cursor + (count > 0 ? count - 1 : count + 1), model.rowCount - 1))
        model.setSelected(select, rows: min(model.cursor, last)...max(model.cursor, last))
        model.moveCursor(to: count > 0 ? last + 1 : last - 1)
    }

    // MARK: Selection files

    private enum FileOutcome {
        case done, cancelled, failed(Error)
    }

    /// The file a command names in its argument, or the one the user types; plain names are
    /// files of the source panel's folder.
    private func file(from argument: CommandArgument, prompt: String, proposal: String, detail: String, directory: URL) -> URL? {
        if let url = argument.location { return url }
        guard let text = (argument.text ?? ui.prompt(prompt, value: proposal, detail: detail))?.trimmingCharacters(in: .whitespaces),
              !text.isEmpty else { return nil }
        return kernel.fileSystems.location(from: text, relativeTo: directory)
    }

    /// Save Selection To File (spec 03 › Selection files): the selected names, or the name
    /// under the cursor, written through the file system the file lies on. The text is made
    /// and written in the job; the old file stays until the new one is complete.
    func saveToFile(_ encoding: SelectionFile.Encoding, argument: CommandArgument) {
        let model = source
        // The marked entries are picked out in the job, not here (a long selection).
        let (operands, directory) = (model.operandsSnapshot(), model.directory)
        guard operands.markedCount > 0 || operands.cursorItem != nil else { return }
        let fileSystems = kernel.fileSystems
        guard var url = file(from: argument, prompt: "Save selection to file", proposal: "",
                             detail: "File name in \(fileSystems.displayPath(directory)); .txt is added to a name without extension.",
                             directory: directory) else { return }
        if url.pathExtension.isEmpty { url = url.appendingPathExtension("txt") }
        let (ui, target) = (self.ui, url)
        kernel.jobs.run(title: "Saving selection:", work: { monitor -> FileOutcome in
            var temporary: URL?
            do {
                let provider = try fileSystems.provider(for: target)
                var replaces = false
                if provider.item(at: target) != nil {
                    let replace = monitor.ask {
                        ui.choose("\(fileSystems.displayPath(target)) already exists.", detail: "Do you want to overwrite it?",
                                  buttons: ["Overwrite", "Cancel"], style: .warning) == 0
                    }
                    guard replace else { return .cancelled }
                    replaces = true
                }
                let data = SelectionFile.encode(operands.items(), as: encoding)
                // Written beside the target and moved into place when complete: a write that
                // fails leaves the old file as it was.
                let beside = target.deletingLastPathComponent().appending(name: ".\(target.lastPathComponent).afm-\(UUID().uuidString.prefix(8)).tmp")
                temporary = beside
                let writer = try provider.write(beside, cancellation: monitor.cancellation)
                let token = monitor.cancellation.interrupting(writer)
                defer { withExtendedLifetime(token) {} }
                try writer.write(data)
                try writer.close(attributes: FileAttributes())
                guard !monitor.cancellation.isCancelled else {
                    try? provider.remove(beside)
                    return .cancelled
                }
                do {
                    try provider.move(beside, to: target, replacing: replaces)
                } catch where replaces {
                    // A file system that cannot replace in one step: the old file goes, the
                    // complete new one is moved in at once.
                    try provider.remove(target)
                    try provider.move(beside, to: target, replacing: false)
                }
                return .done
            } catch {
                if let temporary, let provider = try? fileSystems.provider(for: temporary) { try? provider.remove(temporary) }
                return .failed(error)
            }
        }, completion: { [kernel] outcome in
            switch outcome {
            case .failed(let error): kernel.ui.report(error, title: "The selection cannot be saved!")
            case .done: kernel.panels.refresh([target.deletingLastPathComponent()])
            case .cancelled: break
            }
        })
    }

    /// Selection files are small; a file that is not one is not read to its end.
    private static let readLimit = 32 << 20

    /// Load Selection From File: selects exactly the listed names that the panel shows. The
    /// file is read and its names picked out in the job, which ends when it is cancelled; the
    /// entries are then found like those of any mask.
    func loadFromFile(argument: CommandArgument) {
        let model = source
        let directory = model.directory
        let proposal = model.cursorFile.flatMap { $0.ext.lowercased() == "txt" ? $0.name : nil } ?? ""
        let fileSystems = kernel.fileSystems
        guard let url = file(from: argument, prompt: "Load selection from file", proposal: proposal,
                             detail: "File name in \(fileSystems.displayPath(directory)), or a full path.", directory: directory) else { return }
        let items = model.items
        kernel.jobs.run(title: "Loading selection:", work: { monitor -> Result<ListedNames?, Error> in
            Result {
                let reader = try fileSystems.provider(for: url).read(url, cancellation: monitor.cancellation)
                defer { reader.close() }
                // A read blocked on a server ends when the job is cancelled.
                let token = monitor.cancellation.interrupting(reader)
                defer { withExtendedLifetime(token) {} }
                var data = Data()
                while data.count < Selections.readLimit, !monitor.cancellation.isCancelled, let block = try reader.read(upToCount: 1 << 20) {
                    data.append(autoreleasepool { block })
                }
                guard !monitor.cancellation.isCancelled else { return nil }
                return ListedNames(SelectionFile.text(from: data), among: items)
            }
        }, completion: { [weak self] result in
            switch result {
            case .failure(let error): self?.ui.report(error, title: "The selection cannot be loaded!")
            case .success(let names?): self?.select(names, in: model, directory: directory)
            case .success(nil): break
            }
        })
    }

    /// `cm_LoadSelectionFromClip`: the same with the text on the clipboard. The clipboard is
    /// read once, on the main thread (the pasteboard is not safe against use from two threads
    /// at once); the lines are matched against the names off the main thread, and the text may
    /// be as big as memory.
    func loadFromClipboard() {
        let model = source
        let (items, directory) = (model.items, model.directory)
        guard let text = pasteboard.string(forType: .string), text.utf8.count <= Selections.clipboardLimit else {
            return kernel.commands.onRejected()
        }
        guard background, items.count > Selections.longList || text.utf8.count > Selections.longList * 8 else {
            return select(ListedNames(text, among: items), in: model, directory: directory)
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let names = autoreleasepool { ListedNames(text, among: items) }
            DispatchQueue.main.async { self?.select(names, in: model, directory: directory) }
        }
    }

    /// The most text taken from the clipboard as a list of names.
    private static let clipboardLimit = 64 << 20

    /// The entries a text of names stands for: the ones whose name is written exactly like a
    /// line, and, for a line no entry is written like, the ones that read the same.
    struct ListedNames {
        private var exact = Set<NameBytes>()
        private var alike = Set<String>()

        init(_ text: String, among items: [FileItem]) {
            let known = Set(items.map(\.name))
            let written = Set(items.map { NameBytes($0.name) })
            for name in SelectionFile.listed(in: text, among: known) {
                if written.contains(NameBytes(name)) { exact.insert(NameBytes(name)) } else { alike.insert(name) }
            }
        }

        var isEmpty: Bool { exact.isEmpty && alike.isEmpty }

        func contains(_ item: FileItem) -> Bool {
            exact.contains(NameBytes(item.name)) || (!alike.isEmpty && alike.contains(item.name))
        }
    }

    private func select(_ names: ListedNames, in model: PanelModel, directory: URL) {
        // The panel may have gone elsewhere while the names were found.
        guard model.directory.isSameLocation(as: directory) else { return }
        if names.isEmpty { return model.selectionCount == 0 ? () : model.clearSelection() }
        mark(model, .replace, matching: names.contains)
    }

    // MARK: Comparing the panels

    /// Compare Directories (spec 09 › Compare directories and Mark newer): in both panels the
    /// selection becomes the files that differ from the other side. Whether the volumes tell
    /// upper from lower case is asked of them, which can take long: it is done with the
    /// comparison, off the main thread, and given up when a newer command starts.
    func compare(mode: DirectoryComparison.Mode, withSubdirectories: Bool) {
        let (left, right) = (kernel.panels.left.model, kernel.panels.right.model)
        let (leftFolder, rightFolder) = (left.directory, right.directory)
        let ignoresOneHour = store.ignoresOneHour
        compute(heavy: true, models: [left, right], { [weak self] frozen, flag in
            DirectoryComparison.compareIndices(left: frozen[0].items, right: frozen[1].items, mode: mode, withSubdirectories: withSubdirectories,
                                               ignoringOneHour: ignoresOneHour,
                                               foldingCase: self?.foldsCase(leftFolder, rightFolder, cancellation: flag) ?? false,
                                               cancelled: { flag.isCancelled })
        }, apply: { frozen, marks in
            // Both are tried: a panel that has changed is worked out again with the other.
            let first = Selections.take(marks.left, .replace, in: frozen[0])
            let second = Selections.take(marks.right, .replace, in: frozen[1])
            return first && second
        })
    }

    /// Whether both folders are on local volumes that treat `A.txt` and `a.txt` as one name.
    /// Asks the volumes on a thread of the kernel's, which is given up when `cancellation`
    /// is set (a stalled mount holds that thread, not this one); not for the main thread.
    private func foldsCase(_ folders: URL..., cancellation: CancellationFlag) -> Bool {
        folders.allSatisfy { folder in
            guard folder.isFileURL else { return false }
            let key = "case " + folder.path
            let answer = BlockingCalls.answer(from: self, to: key, cancellation: cancellation) { _ in
                (try? folder.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames == false
            }
            return answer ?? false
        }
    }

    /// Mark Newer, Hide Same Files: marks like Compare Directories and leaves what is the
    /// same on both sides out of both lists, until the command is chosen again or the panel
    /// shows another directory. Nothing is deleted.
    func markNewerHideSame() {
        let models = [kernel.panels.left.model, kernel.panels.right.model]
        if models.contains(where: { shows(.comparison, in: $0) }) { return models.forEach { end(.comparison, in: $0) } }
        let folders = models.map(\.directory)
        let ignoresOneHour = store.ignoresOneHour
        let titles = folders.map { folder -> String in
            let path = kernel.fileSystems.displayPath(folder)
            return "Comparison: " + path + (path.hasSuffix("/") ? "" : "/") + "*.*"
        }
        /// What the work leaves for the main thread: the lists as the filters leave them, and the names to mark.
        struct Outcome {
            var filters: [PanelModel.Prepared]
            var marked: [Set<NameBytes>]
        }
        compute(heavy: true, models: models, { [weak self] frozen, flag in
            let (leftList, rightList) = (frozen[0].basis.listedItems, frozen[1].basis.listedItems)
            let marks = DirectoryComparison.compareIndices(left: leftList, right: rightList, mode: .newer, ignoringOneHour: ignoresOneHour,
                                                           foldingCase: self?.foldsCase(folders[0], folders[1], cancellation: flag) ?? false,
                                                           cancelled: { flag.isCancelled })
            // Exact bytes, so that of two names that differ in normalisation only the same one is left out.
            var same = Set<NameBytes>()
            for index in marks.sameLeft { same.insert(NameBytes(leftList[index].name)) }
            for index in marks.sameRight { same.insert(NameBytes(rightList[index].name)) }
            let filters = zip(frozen, titles).map { frozen, title in
                PanelModel.prepare(frozen.basis, filter: PanelFilter(title: title) { !same.contains(NameBytes($0.name)) })
            }
            return Outcome(filters: filters, marked: [Set(marks.left.map { NameBytes(leftList[$0].name) }),
                                                      Set(marks.right.map { NameBytes(rightList[$0].name) })])
        }, apply: { [weak self] _, outcome in
            guard let self else { return true }
            var fresh = true
            for (model, prepared) in zip(models, outcome.filters) where model.apply(prepared) == .stale { fresh = false }
            guard fresh else { return false }
            for ((model, title), marked) in zip(zip(models, titles), outcome.marked) {
                self.restrictions = self.restrictions.filter { $0.value.model != nil }
                self.restrictions[ObjectIdentifier(model)] = Restriction(model: model, view: .comparison, directory: model.directory, title: title)
                self.mark(model, .replace, matching: { marked.contains(NameBytes($0.name)) })
            }
            return true
        })
    }

    // MARK: Lists shown in part

    func shows(_ view: RestrictedView, in model: PanelModel) -> Bool {
        guard let restriction = restrictions[ObjectIdentifier(model)], restriction.model === model, restriction.view == view else { return false }
        // Another filter may have taken the place of this one since.
        return model.filter?.title == restriction.title
    }

    private func end(_ view: RestrictedView, in model: PanelModel) {
        guard shows(view, in: model) else { return }
        restrictions[ObjectIdentifier(model)] = nil
        model.setFilter(nil)
    }

    private func locationChanged(of model: PanelModel) {
        guard let restriction = restrictions[ObjectIdentifier(model)], restriction.model === model,
              !restriction.directory.isSameLocation(as: model.directory) else { return }
        end(restriction.view, in: model)
        restrictions[ObjectIdentifier(model)] = nil
    }
}

/// Hands a block to the main thread through the run loop (all modes that count), not through the
/// main dispatch queue: a block that asks the user something runs a modal dialog, and a dialog
/// started from inside a block of the main queue keeps every later block of the queue waiting.
func performOnMainLoop(_ block: @escaping () -> Void) {
    RunLoop.main.perform(inModes: [.common], block: block)
    CFRunLoopWakeUp(CFRunLoopGetMain())
}
