import AFMContracts
public import AFMKernel
import Foundation

/// The Show menu: the view of the file list, the plugin columns, which files are listed, the
/// sort order and hidden files (spec 03 › View types, 03 › Custom columns, 03 › Display
/// filters, 03 › Sort keys, 03 › Hidden and system items).
///
/// The commands only change the state of the source panel and its model; the panel on screen
/// follows by itself. Nothing here touches a file system. The plugin's state belongs to the
/// main thread; a long list is sorted and filtered on a background thread and the result is
/// handed to the model on the main thread, where nothing of that length is ever worked through.
public final class ViewOptionsPlugin: Plugin {
    public let name = "View options"

    /// The display filters of the Show menu. `cm_SrcUserDef` takes the specification as its
    /// `.text` argument; without one it asks.
    static let allFiles: CommandID = "cm_SrcAllFiles"
    static let programs: CommandID = "cm_SrcExecs"
    static let lastCustomFilter: CommandID = "cm_SrcUserSpec"
    static let customFilter: CommandID = "cm_SrcUserDef"
    static let onlySelected: CommandID = "cm_ShowOnlySelected"
    /// The dialog that chooses the plugin columns of the source panel.
    static let customColumns: CommandID = "cm_CustomColumnConfig"

    static let hiddenInBothPanelsKey = "viewOptions.hiddenInBothPanels"
    static let programMasksKey = "viewOptions.programMasks"
    static let columnsSwitchToFullKey = "viewOptions.columnsSwitchToFull"
    static let lastMaskKey = "viewOptions.lastMask"
    static let defaultProgramMasks = "*.app *.command *.sh *.workflow"

    /// Which of the Show menu's filters a tab has.
    private enum FilterKind {
        case programs, custom, selected
    }

    /// The filter this plugin gave a tab. It counts for as long as the tab's filter still
    /// carries its title: someone who lays a filter over it (the quick filter) keeps the title
    /// in front, and someone who replaces it does not.
    private struct Applied {
        weak var model: PanelModel?
        let kind: FilterKind
        let title: String
    }

    private var applied: [ObjectIdentifier: Applied] = [:]

    /// Where long lists are worked through, and how the result comes back to the main
    /// thread. Tests put their own in, to say when each happens.
    var background: (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) }
    var onMain: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }

    public init() {}

    public func start(in kernel: Kernel) {
        registerViews(in: kernel)
        registerFilters(in: kernel)
        registerSorting(in: kernel)

        kernel.preferences.add(
            PreferencePage(
                title: "Display",
                preferences: [
                    Preference(
                        Self.hiddenInBothPanelsKey, "Hidden Files switches both panels at once",
                        .flag(default: true)),
                    Preference(
                        Self.programMasksKey, "Show › Programs lists executable files and",
                        .text(default: Self.defaultProgramMasks)),
                    Preference(
                        Self.columnsSwitchToFullKey, "Choosing custom columns switches to the Full view",
                        .flag(default: true))
                ]))
    }

    // MARK: Views and columns

    private func registerViews(in kernel: Kernel) {
        let commands = kernel.commands
        let source = { kernel.panels.source }
        let views: [(CommandID, String, Shortcut, PanelViewMode, String, String)] = [
            (.viewBrief, "Brief", .f(1, .control), .brief, "list.bullet", "Show only the names, in several columns."),
            (
                .viewFull, "Full", .f(2, .control), .full, "list.dash",
                "Show one row per file, with size, date and attributes."
            ),
            (
                .viewThumbnails, "Thumbnail View", .f(1, [.control, .shift]), .thumbnails, "square.grid.2x2",
                "Show pictures of the files."
            )
        ]
        for (id, title, shortcut, mode, symbol, hint) in views {
            commands.register(Command(id, title, [shortcut]), checked: { source().viewMode == mode }) {
                source().viewMode = mode
            }
            kernel.toolbar.add(id, symbol: symbol, group: 60, hint: hint)
        }
        commands.register(
            Command(Self.customColumns, "Custom Columns…", [.f(1, .shift)]),
            enabled: { !kernel.columns.all.isEmpty }
        ) { [self] in chooseColumns(in: kernel) }

        kernel.menus.add(views.map(\.0) + [Self.customColumns], to: .showViewType)
    }

    /// One checkbox per column the plugins offer. The columns that stay keep their order;
    /// new ones go to the end, in the order the plugins registered them.
    private func chooseColumns(in kernel: Kernel) {
        let panel = kernel.panels.source
        let offered = kernel.columns.all
        let fields =
            [FormField.note("Columns shown after the standard ones in the Full view:")]
            + offered.map { FormField.checkbox($0.id, $0.title, panel.extraColumns.contains($0.id)) }
        guard let answer = kernel.ui.form("Custom Columns", detail: "", fields: fields, buttons: ["OK"]) else { return }
        let chosen = Set(offered.map(\.id).filter(answer.flag))
        // An id whose plugin is not loaded is not in the dialog and stays as it is.
        let known = Set(offered.map(\.id))
        let kept = panel.extraColumns.filter { chosen.contains($0) || !known.contains($0) }
        let columns = kept + offered.map(\.id).filter { chosen.contains($0) && !kept.contains($0) }
        guard columns != panel.extraColumns else { return }
        panel.extraColumns = columns
        if !chosen.isEmpty, kernel.settings.flag(Self.columnsSwitchToFullKey, default: true) {
            panel.viewMode = .full
        }
    }

    // MARK: Display filters

    private func registerFilters(in kernel: Kernel) {
        let commands = kernel.commands
        let model = { kernel.panels.source.model }
        let settings = kernel.settings
        let kind = { [self] in kind(of: model()) }

        commands.register(
            Command(Self.allFiles, "All Files", [.f(10, .control)]), checked: { model().filter == nil }
        ) { [self] in
            apply(nil, as: nil, to: model())
        }
        commands.register(
            Command(Self.programs, "Programs", [.f(11, .control)]), checked: { kind() == .programs }
        ) { [self] in
            let masks = FileMask(
                settings.text(Self.programMasksKey, default: Self.defaultProgramMasks))
            apply(
                PanelFilter(title: "<programs>") { Self.isProgram($0, masks: masks) }, as: .programs,
                to: model())
        }
        commands.register(
            Command(Self.lastCustomFilter, "Last Custom Filter"),
            enabled: { settings.data(forKey: Self.lastMaskKey) != nil }
        ) { [self] in
            apply(
                DisplayMask(settings.text(Self.lastMaskKey, default: "*.*")).filter, as: .custom,
                to: model())
        }
        commands.register(
            Command(Self.customFilter, "Custom…", [.f(12, .control)]), checked: { kind() == .custom },
            parameterized: { [self] argument in
                let last = settings.text(Self.lastMaskKey, default: "*.*")
                guard
                    let text = argument.text
                        ?? kernel.ui.prompt(
                            "Enter file types (e.g. *.doc *.txt)", value: last,
                            detail: "Masks after “|” are left out; “| name/” hides folders.")
                else { return }
                let mask = DisplayMask(text)
                if !mask.text.isEmpty { settings.set(mask.text, forKey: Self.lastMaskKey) }
                // `*.*` shows everything: the filter is taken away.
                apply(mask.filter, as: .custom, to: model())
            })
        commands.register(
            Command(Self.onlySelected, "Only Selected Files"), enabled: { model().hasSelection },
            checked: { kind() == .selected }
        ) { [self] in
            // A snapshot: marking other files later does not bring hidden ones back. The marks
            // are taken as they are (nothing is copied); the names are picked out in the background.
            let marks = model().operandsSnapshot()
            apply("<selected>", as: .selected, to: model()) {
                let names = Set(marks.markedItems().map(\.name))
                return PanelFilter(title: "<selected>") { names.contains($0.name) }
            }
        }
        // Hidden files are shown or hidden in every tab, of both panels unless the user wants it otherwise.
        commands.register(Command(.showHidden, "Hidden Files", [.cmd(".", .shift)]), checked: { model().showHidden }) {
            let show = !model().showHidden
            let both = settings.flag(Self.hiddenInBothPanelsKey, default: true)
            for panel in both ? kernel.panels.all : [kernel.panels.source] {
                panel.tabs.tabs.forEach { $0.setShowHidden(show) }
                panel.reload()
            }
        }
        kernel.toolbar.setSymbol("eye", for: .showHidden)

        kernel.menus.add(
            [
                Self.allFiles, Self.programs, Self.lastCustomFilter,
                Self.customFilter, Self.onlySelected, .showHidden
            ], to: .showFilters)
    }

    /// Lists from this length on are filtered in the background.
    static let backgroundFilterThreshold = 20_000
    /// How often a result that the list outgrew (a folder that changes while the work is
    /// done) is worked out again in the background before the main thread does it: it is
    /// one pass on all cores, and the user gets the filter or the order they asked for.
    static let staleTries = 3
    /// The number of the filter each panel was given last: a result that comes back for an
    /// older one is dropped. The numbers are never used twice.
    private var filterTickets: [ObjectIdentifier: Int] = [:]
    private var lastFilterTicket = 0

    private func apply(_ filter: PanelFilter?, as kind: FilterKind?, to model: PanelModel) {
        apply(filter?.title, as: kind, to: model) { filter }
    }

    /// Gives a tab a display filter, or with nil takes away whatever filter it has. A long
    /// list is filtered on a background thread (on all cores) and the result handed to the
    /// model; should the list have changed by then, the new one is filtered, again in the
    /// background. `make` builds the filter (in the background too, for a long list);
    /// `matches` of it is then called from several threads and looks at the entry alone.
    private func apply(
        _ title: String?, as kind: FilterKind?, to model: PanelModel, make: @escaping () -> PanelFilter?
    ) {
        applied = applied.filter { $0.value.model != nil }
        filterTickets = filterTickets.filter { applied[$0.key] != nil }
        let id = ObjectIdentifier(model)
        if let title, let kind {
            applied[id] = Applied(model: model, kind: kind, title: title)
        } else {
            applied[id] = nil
        }
        lastFilterTicket += 1
        let ticket = lastFilterTicket
        filterTickets[id] = ticket
        // Taking a filter away shows the list as it is: nothing to work through.
        guard title != nil, model.listedItems.count >= Self.backgroundFilterThreshold else {
            model.setFilter(make())
            return
        }
        filterInBackground(model, make, ticket: ticket, tries: 1)
    }

    private func filterInBackground(_ model: PanelModel, _ make: @escaping () -> PanelFilter?, ticket: Int, tries: Int)
    {
        let id = ObjectIdentifier(model)
        let basis = model.basis
        background { [self] in
            let prepared = PanelModel.prepare(basis, filter: make())
            onMain { [self] in
                // A later filter has taken over.
                guard filterTickets[id] == ticket else { return }
                if model.apply(prepared) != .stale { return }
                if model.listedItems.count < Self.backgroundFilterThreshold
                    || tries >= Self.staleTries
                {
                    // The list is short now, or it keeps changing faster than it can be filtered.
                    model.setFilter(make())
                } else {
                    filterInBackground(model, make, ticket: ticket, tries: tries + 1)
                }
            }
        }
    }

    private func kind(of model: PanelModel) -> FilterKind? {
        guard let entry = applied[ObjectIdentifier(model)], entry.model === model, let title = model.filter?.title,
            title.hasPrefix(entry.title)
        else { return nil }
        return entry.kind
    }

    /// What Show › Programs lists on a Mac: applications, files that may be executed, and the
    /// files the user's masks name (the Windows list is `*.exe *.com *.bat`). Folders stay.
    static func isProgram(_ item: FileItem, masks: FileMask) -> Bool {
        if item.isFolder { return true }
        if masks.matches(item.name) { return true }
        return !item.isDirectory && item.permissions & 0o111 != 0
    }

    // MARK: Sorting

    /// Lists from this length on are sorted in the background.
    static let backgroundSortThreshold = 20_000
    /// The order each panel was last asked for and has not got yet. It stays the wish until it
    /// is met: every sort that goes stale starts again from the list as it is.
    private var pendingOrders: [ObjectIdentifier: ListOrder] = [:]

    /// Gives a panel the order `change` makes of its present one. A short list is sorted on
    /// the spot. A long one is sorted on a background thread and handed to the panel when
    /// it is done, so the window stays alive meanwhile.
    private func sort(_ model: PanelModel, reload: @escaping () -> Void, _ change: (ListOrder) -> ListOrder) {
        let id = ObjectIdentifier(model)
        let order = change(pendingOrders[id] ?? model.wantedSort)
        // Unsorted takes the list as it is (no work, whatever the length); the order the entries
        // came in is gone from a list that was sorted, so the folder is read again.
        if order.key == .unsorted {
            pendingOrders[id] = nil
            let isAsItCame = model.isInArrivalOrder
            model.setSort(order)
            if !isAsItCame { reload() }
            return
        }
        guard model.listedItems.count >= Self.backgroundSortThreshold else {
            pendingOrders[id] = nil
            model.setSort(order)
            return
        }
        pendingOrders[id] = order
        // The wish is the model's from here on: a reading of the folder that arrives while
        // the list is being sorted brings this order with it.
        model.requestSort(order)
        sortInBackground(model, to: order)
    }

    /// Sorts a copy of the list off the main thread. The model knows the order that is
    /// wanted (`requestSort`), so a folder that changes while the copy is sorted costs
    /// nothing here: the reading that arrives is taken in that order by whoever reads it,
    /// and the result made here is then of no use. Only a change that brings no list (another
    /// filter) leaves the list in its old order; then it is sorted again, in the background
    /// as before. Nothing is ever sorted on the main thread for a long list.
    private func sortInBackground(_ model: PanelModel, to order: ListOrder) {
        let id = ObjectIdentifier(model)
        let basis = model.basis
        background { [self] in
            let prepared = PanelModel.prepare(basis, sort: order)
            onMain { [self] in
                // A later command has taken over.
                guard pendingOrders[id] == order else { return }
                if model.apply(prepared) != .stale || model.sort == order {
                    // Sorted here, or brought in this order by a reading meanwhile.
                    pendingOrders[id] = nil
                    return
                }
                // The order was changed by another route meanwhile (a click on a column, a
                // restored tab): that one is the newer wish, and this result is dropped.
                guard model.requestedSort == order else {
                    pendingOrders[id] = nil
                    return
                }
                guard model.listedItems.count >= Self.backgroundSortThreshold else {
                    // The list is short now.
                    pendingOrders[id] = nil
                    return model.setSort(order)
                }
                sortInBackground(model, to: order)
            }
        }
    }

    private func registerSorting(in kernel: Kernel) {
        let commands = kernel.commands
        let model = { kernel.panels.source.model }
        let reload = { kernel.panels.source.reload() }
        let sortCommands: [(CommandID, String, Int, SortKey)] = [
            (.sortByName, "Name", 3, .name), (.sortByExtension, "Extension", 4, .ext), (.sortByTime, "Time", 5, .date),
            (.sortBySize, "Size", 6, .size), (.unsorted, "Unsorted", 7, .unsorted)
        ]
        for (id, title, functionKey, key) in sortCommands {
            commands.register(Command(id, title, [.f(functionKey, .control)]), checked: { model().sort.key == key }) {
                [self] in
                sort(model(), reload: reload) { _ in ListOrder(key: key, descending: key.startsDescending) }
            }
        }
        commands.register(Command(.reversedOrder, "Reversed Order"), checked: { model().sort.descending }) { [self] in
            sort(model(), reload: reload) { current in ListOrder(key: current.key, descending: !current.descending) }
        }

        kernel.menus.add(sortCommands.map(\.0), to: .showSortKey)
        kernel.menus.add([.reversedOrder], to: .showSortDirection)
    }
}
