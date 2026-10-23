import AFMContracts
public import AFMKernel
import Dispatch

/// The Show menu: the view of the file list, the plugin columns, which files are listed, the
/// sort order and hidden files (spec 03 › View types, 03 › Custom columns, 03 › Display
/// filters, 03 › Sort keys, 03 › Hidden and system items).
///
/// The commands only change the state of the source panel and its model; the panel on screen
/// follows by itself. Nothing here touches a file system. The plugin's state belongs to the
/// main thread; a long list is sorted and filtered on a background thread and the result is
/// handed to the model on the main thread, where nothing of that length is ever worked through.
public final class ViewOptionsPlugin: Plugin {
    /// Which of the Show menu's filters a tab has.
    private enum FilterKind {
        case programs, custom, selected
    }

    /// The filter this plugin gave a tab.
    ///
    /// It counts for as long as the tab's filter still carries its title: someone who lays a filter
    /// over it (the quick filter) keeps the title in front, and someone who replaces it does not.
    private struct Applied {
        weak var model: PanelModel?
        let kind: FilterKind
        let title: String
    }

    /// Show › All Files: takes the display filter away.
    internal static let allFiles: CommandID = "cm_SrcAllFiles"
    /// Show › Programs: lists what can be run, with the user's masks (`programMasksKey`).
    internal static let programs: CommandID = "cm_SrcExecs"
    /// Show › Last Custom Filter: the mask stored under `lastMaskKey` again, without asking.
    internal static let lastCustomFilter: CommandID = "cm_SrcUserSpec"
    /// Show › Custom…: takes the specification as its `.text` argument; without one it asks.
    internal static let customFilter: CommandID = "cm_SrcUserDef"
    /// Show › Only Selected Files: lists the marked files only, as they are marked now.
    internal static let onlySelected: CommandID = "cm_ShowOnlySelected"
    /// The dialog that chooses the plugin columns of the source panel.
    internal static let customColumns: CommandID = "cm_CustomColumnConfig"

    /// The setting that makes Hidden Files switch both panels (true unless the user says otherwise).
    internal static let hiddenInBothPanelsKey = "viewOptions.hiddenInBothPanels"
    /// The setting with the masks that Show › Programs lists besides executable files.
    internal static let programMasksKey = "viewOptions.programMasks"
    /// The setting that makes choosing custom columns switch the panel to the Full view.
    internal static let columnsSwitchToFullKey = "viewOptions.columnsSwitchToFull"
    /// The setting with the last specification typed into Show › Custom…; there only once one was typed.
    internal static let lastMaskKey = "viewOptions.lastMask"
    /// The masks of Show › Programs until the user sets their own: the Mac's runnable files.
    internal static let defaultProgramMasks = "*.app *.command *.sh *.workflow"

    /// Lists from this length on are filtered in the background.
    internal static let backgroundFilterThreshold = 20_000
    /// How often a result that the list outgrew (a folder that changes while the work is
    /// done) is worked out again in the background before the main thread does it: it is
    /// one pass on all cores, and the user gets the filter or the order they asked for.
    internal static let staleTries = 3

    /// Lists from this length on are sorted in the background.
    internal static let backgroundSortThreshold = 20_000

    /// The plugin's name in the list of plugins.
    public let name = "View options"

    /// Where long lists are worked through, and how the result comes back to the main
    /// thread.
    ///
    /// Tests put their own in, to say when each happens.
    internal var background: @Sendable (@escaping @Sendable () -> Void) -> Void = { work in
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }
    /// Hands the result of background work back to the main thread; tests put their own in.
    internal var onMain: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void = { work in
        // The main queue runs its blocks on the main thread.
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }
    /// The order each panel was last asked for and has not got yet.
    ///
    /// It stays the wish until it is met: every sort that goes stale starts again from the list as
    /// it is. Kept by the sorting commands (`ViewOptionsPlugin+Sorting.swift`), on the main thread.
    internal var pendingOrders: [ObjectIdentifier: ListOrder] = [:]

    private var applied: [ObjectIdentifier: Applied] = [:]

    /// The number of the filter each panel was given last: a result that comes back for an
    /// older one is dropped.
    ///
    /// The numbers are never used twice.
    private var filterTickets: [ObjectIdentifier: Int] = [:]
    private var lastFilterTicket = 0

    /// A plugin with nothing registered yet; `start(in:)` registers its commands.
    public init() {
        // Every table starts empty and fills as the commands are used.
    }

    /// What Show › Programs lists on a Mac: applications, files that may be executed, and the
    /// files the user's masks name (the Windows list is `*.exe *.com *.bat`).
    ///
    /// Folders stay.
    nonisolated internal static func isProgram(_ item: FileItem, masks: FileMask) -> Bool {
        if item.isFolder {
            return true
        }
        if masks.matches(item.name) {
            return true
        }
        return !item.isDirectory && item.permissions & 0o111 != 0
    }

    /// Registers the commands of the Show menu, their keys, menus and toolbar buttons, and the
    /// Display page of the preferences.
    public func start(in kernel: Kernel) {
        registerViews(in: kernel)
        registerFilters(in: kernel)
        registerSorting(in: kernel)

        kernel.preferences.add(
            PreferencePage(
                title: "Display",
                preferences: [
                    Preference(
                        Self.hiddenInBothPanelsKey,
                        "Hidden Files switches both panels at once",
                        .flag(default: true)
                    ),
                    Preference(
                        Self.programMasksKey,
                        "Show › Programs lists executable files and",
                        .text(default: Self.defaultProgramMasks)
                    ),
                    Preference(
                        Self.columnsSwitchToFullKey,
                        "Choosing custom columns switches to the Full view",
                        .flag(default: true)
                    )
                ]
            )
        )
    }

    // MARK: Display filters

    /// The display filters and Hidden Files, in the Show menu.
    private func registerFilters(in kernel: Kernel) {
        registerAllFilesAndPrograms(in: kernel)
        registerCustomFilters(in: kernel)
        registerOnlySelected(in: kernel)
        registerHiddenFiles(in: kernel)
        kernel.menus.add(
            [
                Self.allFiles, Self.programs, Self.lastCustomFilter,
                Self.customFilter, Self.onlySelected, .showHidden
            ],
            to: .showFilters
        )
    }

    /// All Files, which takes the filter away, and Programs.
    private func registerAllFilesAndPrograms(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        let model = { kernel.panels.source.model }
        let settings = kernel.settings
        kernel.commands.register(
            Command(Self.allFiles, "All Files", [.f(10, .control)]),
            checked: { model().filter == nil },
            { [self] in apply(nil, as: nil, to: model()) }
        )
        kernel.commands.register(
            Command(Self.programs, "Programs", [.f(11, .control)]),
            checked: { [self] in kind(of: model()) == .programs },
            { [self] in
                let masks = FileMask(settings.text(Self.programMasksKey, default: Self.defaultProgramMasks))
                apply(
                    PanelFilter(title: "<programs>") { Self.isProgram($0, masks: masks) },
                    as: .programs,
                    to: model()
                )
            }
        )
    }

    /// Custom…, which asks for a specification unless it is given one, and the last one again.
    private func registerCustomFilters(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        let model = { kernel.panels.source.model }
        let settings = kernel.settings
        kernel.commands.register(
            Command(Self.lastCustomFilter, "Last Custom Filter"),
            enabled: { settings.data(forKey: Self.lastMaskKey) != nil },
            { [self] in
                apply(DisplayMask(settings.text(Self.lastMaskKey, default: "*.*")).filter, as: .custom, to: model())
            }
        )
        kernel.commands.register(
            Command(Self.customFilter, "Custom…", [.f(12, .control)]),
            checked: { [self] in kind(of: model()) == .custom },
            parameterized: { [self] argument in
                let last = settings.text(Self.lastMaskKey, default: "*.*")
                guard
                    let text = argument.text
                        ?? kernel.interaction.prompt(
                            "Enter file types (e.g. *.doc *.txt)",
                            value: last,
                            detail: "Masks after “|” are left out; “| name/” hides folders."
                        )
                else { return }
                let mask = DisplayMask(text)
                if !mask.text.isEmpty { settings.set(mask.text, forKey: Self.lastMaskKey) }
                // `*.*` shows everything: the filter is taken away.
                apply(mask.filter, as: .custom, to: model())
            }
        )
    }

    /// Only Selected Files: a filter of the names marked when the command runs.
    private func registerOnlySelected(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        let model = { kernel.panels.source.model }
        kernel.commands.register(
            Command(Self.onlySelected, "Only Selected Files"),
            enabled: { model().hasSelection },
            checked: { [self] in kind(of: model()) == .selected },
            { [self] in
                // A snapshot: marking other files later does not bring hidden ones back. The marks
                // are taken as they are (nothing is copied); the names are picked out in the background.
                let marks = model().operandsSnapshot()
                apply("<selected>", as: .selected, to: model()) {
                    let names = Set(marks.markedItems().map(\.name))
                    return PanelFilter(title: "<selected>") { names.contains($0.name) }
                }
            }
        )
    }

    /// Hidden Files: shown or hidden in every tab, of both panels unless the user wants it otherwise.
    private func registerHiddenFiles(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        let model = { kernel.panels.source.model }
        let settings = kernel.settings
        kernel.commands.register(
            Command(.showHidden, "Hidden Files", [.cmd(".", .shift)]),
            checked: { model().showHidden },
            {
                let show = !model().showHidden
                let both = settings.flag(Self.hiddenInBothPanelsKey, default: true)
                for panel in both ? kernel.panels.all : [kernel.panels.source] {
                    for tab in panel.tabs.tabs {
                        tab.setShowHidden(show)
                    }
                    panel.reload()
                }
            }
        )
        kernel.toolbar.setSymbol("eye", for: .showHidden)
    }

    private func apply(_ filter: PanelFilter?, as kind: FilterKind?, to model: PanelModel) {
        apply(filter?.title, as: kind, to: model) { filter }
    }

    /// Gives a tab a display filter, or with nil takes away whatever filter it has.
    ///
    /// A long list is filtered on a background thread (on all cores) and the result handed to the
    /// model; should the list have changed by then, the new one is filtered, again in the
    /// background. `make` builds the filter (in the background too, for a long list); `matches` of
    /// it is then called from several threads and looks at the entry alone.
    private func apply(
        _ title: String?,
        as kind: FilterKind?,
        to model: PanelModel,
        make: @escaping @Sendable () -> PanelFilter?
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

    private func filterInBackground(
        _ model: PanelModel,
        _ make: @escaping @Sendable () -> PanelFilter?,
        ticket: Int,
        tries: Int
    ) {
        let id = ObjectIdentifier(model)
        let basis = model.basis
        // Taken on the main thread: the background thread does not read the plugin.
        let toMain = onMain
        background { [self] in
            let prepared = PanelModel.prepare(basis, filter: make())
            toMain { [self] in
                // A later filter has taken over.
                guard filterTickets[id] == ticket else {
                    return
                }
                if model.apply(prepared) != .stale {
                    return
                }
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

    deinit {
        // Nothing to release.
    }
}
